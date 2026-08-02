Statistics-layer guard (B7; env-research/Q3-stats.md).  What makes a "Never"
carry a BOUND is the per-window sub-tallies of the control channel: without them
the (instance,run) grid is R = NUMBER_OF_RUN cells with H = 1, a Fano factor
would be estimated from 10 points, and the within-run autocorrelation -- the
thing that actually makes the counts bursty -- would be unmeasurable, because
nothing exposes the count stream inside a run.

The layer's own behaviour is gated by hetlitmus/verify/statscheck.py, which
compiles the real het_verdict.h and drives it with synthetic record streams.
What this file pins is the EMITTER's half: that the harness produces the inputs
the layer consumes, since a perfect estimator fed by a tally that never moves is
indistinguishable from one that works.

  $ litmus7 -o . ../het/MP-cg-sys-fence-2s.litmus >/dev/null 2>&1
  $ litmus7 -o . ../het/2+2W-cg-sys-fence.litmus >/dev/null 2>&1
  $ litmus7 -o . ../het/MP-cg-sys-relaxed.litmus >/dev/null 2>&1

THE RECORDS MUST OUTLIVE THE RUN LOOP.  The statistics are computed over the
(instance,run) cells, so a single reused _rec would leave nothing to aggregate.
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
(e)), and the campaign scheduler retunes budget/goal/seed per invocation without
a rebuild.  The seed base is env-overridable for exactly one reason: growing R
happens by re-invoking with a fresh HET_SEED, and replaying the same seeds would
double-count R_eff.

  $ grep -c 'het_env_long("HET_RUNS_MAX", NUMBER_OF_RUN)' MP-cg-sys-fence-2s/MP-cg-sys-fence-2s.cu
  1
  $ grep -c 'het_env_long("HET_ADAPTIVE", 0)' MP-cg-sys-fence-2s/MP-cg-sys-fence-2s.cu
  1
  $ grep -c 'het_env_double("HET_P_GOAL", -1.0)' MP-cg-sys-fence-2s/MP-cg-sys-fence-2s.cu
  1
  $ grep -c 'het_env_long("HET_SEED", (long)HET_SEED)' MP-cg-sys-fence-2s/MP-cg-sys-fence-2s.cu
  1
  $ grep -c 'uint32_t _seed = _seed0 + (uint32_t)_run;' MP-cg-sys-fence-2s/MP-cg-sys-fence-2s.cu
  1

THE ADAPTIVE STOP IS THE HEADER'S RULE, consulted after every run -- the same
pure function the campaign scheduler applies across invocations, so there is
exactly one stopping policy.  The record also reports the window resolution the
run realised: HET_NWIN is swept, and a record scored at one nwin must never be
pooled with another (B7b).

  $ grep -c 'het_campaign_should_stop(_recs, _nrec, _runs_budget, _p_goal)' MP-cg-sys-fence-2s/MP-cg-sys-fence-2s.cu
  1
  $ grep -c 'HetCampaign MP-cg-sys-fence-2s stop=%s' MP-cg-sys-fence-2s/MP-cg-sys-fence-2s.cu
  1
  $ grep -c '_rec.nwin = (uint32_t)HET_NWIN;' MP-cg-sys-fence-2s/MP-cg-sys-fence-2s.cu
  1

THE COUNT AND ITS WINDOW BUMP RIDE ONE LINE, UNDER ONE PREDICATE.  This is what
makes `sum(control_win[]) == control_target_count' an invariant -- and that
invariant is the only run-time evidence, on real hardware, that the sub-tallies
are alive at all (het_stats_compute raises HET_ST_WIN_DESYNC when it breaks, and
refuses to report a bound).  A window bump that drifted onto its own line under
its own condition could silently stop tracking while every structural gate stayed
green.

  $ grep -c 'if (_weak) { _rec.control_target_count++; _rec.control_win\[het_win_of(_f, SIZE_OF_TEST)\]++; }' MP-cg-sys-fence-2s/MP-cg-sys-fence-2s.cu
  1
  $ grep -c 'if (_weak) { _rec.canary_target_count++; _rec.canary_win\[het_win_of(_f, SIZE_OF_TEST)\]++; }' MP-cg-sys-fence-2s/MP-cg-sys-fence-2s.cu
  1

THE CONTROL CHANNEL, NEVER THE TARGET.  The target is far too rare to estimate a
variance from -- that is the entire reason it needs a bound at all -- so the
test's own scan must not be windowed.  Pinned by counting the WINDOWING CALL, not
by forbidding a field name: het_obs_record has exactly two per-window arrays
(control_win, canary_win) and no third, so a target scan that started windowing
would have to reuse one of them or add one -- either way it is a third het_win_of
call site, and this count is 2 for the two bumps pinned just above.

  $ grep -c 'target_count_exhaustive++; _rec.target_count_heuristic++' MP-cg-sys-fence-2s/MP-cg-sys-fence-2s.cu
  1
  $ grep -c 'het_win_of' MP-cg-sys-fence-2s/MP-cg-sys-fence-2s.cu
  2

THE DEGENERACY GUARD MUST NOT GO CONSTANT ON THE STORE-ONLY SHAPES.
distinct_decoded_iters and skew_stddev are both written from the same
synchrony-decode block, so a test with no synchrony read leaves both at their
memset zero.  11 of the 411 -- every 2+2W, which is store-only and has no reader
at all -- sit in exactly that position, and a guard reading `skew_stddev == 0' as
"the decoder is degenerate" would condemn every cell of all 22 forever, making
k_eff constant 0 and P_rep a constant 1 - e^0 = 0 on them.  0 means NOT MEASURED,
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

THE TWO `self' CANARY ROWS HAVE NO CONTROL STREAM, AND THAT IS BY CONSTRUCTION.
MP-{cg,gc}-sys-relaxed are the Layer-B canary and cannot co-run themselves, so
they carry no window bump.  het_stats_compute must then report FANO_UNMEASURED
and no bound -- and, crucially, must not let the KS gate "pass" on their all-zero
stream, which would unlock a P_rep from a stationarity test that never ran.  They
still compute and print their aggregate; they simply cannot bound anything.

  $ grep -c 'het_win_of' MP-cg-sys-relaxed/MP-cg-sys-relaxed.cu
  0
  [1]
  $ grep -c 'het_stats_compute(_recs, _nrec, &_st);' MP-cg-sys-relaxed/MP-cg-sys-relaxed.cu
  1

THE ESTIMATOR ITSELF IS IN THE EMITTED HEADER, NOT IN A SCRIPT.  The bound has to
travel with the harness: a number a reader cannot recompute from the artefact is
not a result.

  $ grep -c 'static double het_mu_upper(double r)' MP-cg-sys-fence-2s/het_verdict.h
  1
  $ grep -c 'return r \* expm1(L / r);' MP-cg-sys-fence-2s/het_verdict.h
  1
  $ grep -c 'static int het_ks2' MP-cg-sys-fence-2s/het_verdict.h
  1
  $ grep -c 'static int het_cell_degenerate' MP-cg-sys-fence-2s/het_verdict.h
  1

So is the autocorrelation time: the estimator that turns one-bit-per-run into
N_eff effective samples travels with the harness too, cited (Geyer 1992, the
initial-positive-sequence estimator) and clamped to [1, HET_NWIN] in one
direction (B7b).

  $ grep -c 'static double het_tau_ips' MP-cg-sys-fence-2s/het_verdict.h
  1
  $ grep -q 'Statistical Science 7(4), 1992' MP-cg-sys-fence-2s/het_verdict.h && echo cited
  cited
  $ grep -c 'static het_campaign_stop_t het_campaign_should_stop' MP-cg-sys-fence-2s/het_verdict.h
  1

NO SILENT FALLBACK CONSTANT.  The bound must never quietly revert to the textbook
3/N: on a channel whose measured Fano is ~20 that is a ~6x optimistic overclaim
(env-research/impl-briefs/B7-impl-brief.md), and it would make every
non-observation in the thesis look six times stronger than it is.  When the
dispersion cannot be measured, the layer says so and reports no bound.

  $ grep -c 'NO FALSE-NEGATIVE BOUND IS REPORTED' MP-cg-sys-fence-2s/het_verdict.h
  1
  $ grep -q 'HET_ST_FANO_UNMEASURED' MP-cg-sys-fence-2s/het_verdict.h && echo present
  present

A BOUND ABOVE 1 IS NOT A BOUND.  p_run is a probability, so "p < 6e10" is not a
weak claim -- it is the absence of one, and must not be tabulated as a number.

  $ grep -q 'HET_ST_BOUND_VACUOUS' MP-cg-sys-fence-2s/het_verdict.h && echo present
  present
