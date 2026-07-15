/* =========================================================================
 * het_verdict.h -- HetLitmus observation record + null-credibility rule.
 * Emitted by litmus7 (HetArch.het_verdict_h).   DO NOT EDIT.
 *
 * WHAT THIS FILE IS FOR.  A litmus campaign's Disallowed half is the half that
 * validates the compound memory model, and it validates it with NULLS -- with
 * outcomes we did not see.  A null is evidence only if the harness WOULD have
 * seen a weak behaviour had one been permitted.  So every null is gated on a
 * POSITIVE CONTROL that fired on the same run, on the same C2C path, under the
 * same stress:
 *
 *   Layer A  mu(T)   the nearest ALLOWED grid neighbour of the forbidden test
 *                    T -- same shape, same direction, same sys scope, same
 *                    accesses, ONE ordering primitive weaker.  If mu(T) fires,
 *                    the harness demonstrably produced the precise cross-device
 *                    interleaving that T's ordering is claimed to prevent.
 *                    (MC-Mutants "Weakening sw" mutator; the corpus grid
 *                    already contains it -- see tests/het/control-map.csv.)
 *
 *   Layer B  canary  a fixed het MP-{cg,gc}-sys-relaxed instance.  MP is the
 *                    only het shape with a published detected-weak result on
 *                    GH200 (Bagchi ISMM'26 Table 4), so it is the robust floor
 *                    that fires when a stubborn shape does not.
 *
 * BOTH LAYERS ARE THEMSELVES HETEROGENEOUS AND CROSS C2C.  That is the whole
 * point and it is what rules out the obvious cheap controls: a GPU-only (or
 * CPU-only) known-weak behaviour vouches for the on-die window, NOT for the
 * interconnect window the forbidden het tests actually inhabit.
 *
 * DO NOT cite Bagchi's ~0.2% relaxed-MP rate as this control's expected hit
 * rate.  On re-reading the primary PDF that number is the GPU-only INTER-CTA
 * rate (Bagchi 5.1 p.74, attributed to "our Section 4.1 results", where the
 * producer and consumer are both GPU threads on different CTAs).  It fires with
 * no CPU participation and without crossing C2C.  There is NO published numeric
 * het hit-rate anywhere in that paper (Table 4 is qualitative).  The het
 * control/canary hit-rate is HARDWARE-ONLY: measure it, never assume it.
 *
 * WHAT A NULL CAN AND CANNOT BECOME.  The control does NOT upgrade a null to a
 * proof.  It upgrades it from UNINTERPRETABLE to CREDIBLE-NOT-OBSERVED.
 * Falsification is one-sided:
 *
 *     "we emphasise that for correct GPU programming the possibility, not
 *      probability of weak behaviours is what matters."
 *        -- Alglave et al., ASPLOS'15, 4.3, p.585.
 * ========================================================================= */
#ifndef HET_VERDICT_H
#define HET_VERDICT_H

#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>   /* qsort: the two-sample KS stationarity precheck (B7)      */
#include <string.h>   /* strcmp: distinguishing the `self' canary from a missing one */
#include <math.h>

/* ---------------------------------------------------------------------------
 * tau_hot -- how many control sightings make the harness "demonstrably hot".
 *
 * 3 is Kirkham's 95% floor (P_rep = 1 - e^-3 = 95.02%; OOPSLA'20 1.1).  We
 * default to 30 so that "hot" is comfortable rather than marginal -- cheap in a
 * perpetual harness driving N to 1e6-1e7.  Its CALIBRATION is hardware-only
 * (Q4 8.1) and couples to Q3/B7: het CPU-GPU drift and shared-fabric contention
 * can break the stationarity/independence that the Poisson arithmetic assumes,
 * which is exactly why control_Prep below is a HOTNESS INDICATOR and not a
 * guarantee. */
#ifndef HET_TAU_HOT
#define HET_TAU_HOT 30
#endif

/* ---------------------------------------------------------------------------
 * B7 KNOBS -- the statistics layer (see "THE STATISTICS LAYER" at the foot).
 *
 * HET_NWIN.  The recovery scan buckets each run's frames into HET_NWIN windows
 * and sub-tallies the CONTROL channel per window.  This is the enabling piece of
 * machinery for the whole of B7 and it exists because the record could not
 * otherwise support ANY dispersion estimate: the emitter produces ONE record per
 * run, so the (instance,run) grid is R = NUMBER_OF_RUN cells with H = 1, and a
 * Fano factor estimated from 10 points is not a variance estimate, it is noise.
 * Worse, the WITHIN-run autocorrelation -- the thing that actually makes the
 * counts bursty -- was unmeasurable, because nothing exposed the count stream
 * INSIDE a run.  Q3 6.3 defers exactly this and says to spec it: "the
 * dispersion/autocorrelation estimators need the scan to expose per-window
 * control counts, not just the run total."  W windows x R runs is the sample
 * that F_win, the lag-1 autocorrelation and the KS precheck all consume.
 *
 * HET_NWIN IS A SWEPT KNOB, AND IT IS A RESOLUTION FLOOR (B7b).  The window is
 * the finest time-scale the record can see, so the integrated autocorrelation
 * time tau (het_tau_ips below) cannot be resolved below ONE WINDOW -- which is
 * why N_eff = HET_NWIN/tau_w is CLAMPED to [1, HET_NWIN]: HET_NWIN caps the
 * effective sample size a run can ever claim.  At the B7 default of 32 and
 * N = 100000 a window was 3,125 iterations; if the true tau were, say, 100
 * iterations the 32-bucket stream would look nearly white (tau_w ~ 1) and the
 * run would recover N_eff = 32, NOT the ~1000 the physics would support.  The
 * default is therefore raised to 128 (781 iterations/window at the default N),
 * and the knob is SWEPT (-DHET_NWIN=...), not tuned here: make the windows too
 * fine and adjacent windows become correlated, tau_w rises above 1, and the
 * gain cancels -- finding where the returns stop is exactly the estimator's
 * job, so let it tell you.  Do not hardcode a new constant and call it
 * measured.  Every run REPORTS the value it realised (het_obs_record.nwin, and
 * nwin= in the HetStats line), because a knob that says one thing while the
 * run realised another would silently mis-tune B8.
 *
 * (Raising it also strengthens Kirkham's first-20%-vs-last-10% split: 25 early
 * and 12 late window positions per run instead of 6 and 3.)
 *
 * HET_THETA_DISTINCT (theta_d).  The degeneracy guard's floor -- see
 * het_cell_degenerate().  It is deliberately the LITERAL-degeneracy floor (2 =
 * "the decode produced at least two distinct values"), not a statistical filter:
 * the guard's job is to catch Srivastava's constant-read ARTEFACT, and rejecting
 * more than that would start discarding genuine sightings, which falsification
 * forbids ("the possibility, not probability of weak behaviours is what
 * matters" -- Alglave ASPLOS'15 4.3).  Raising it is a hardware-calibration
 * decision, not a free tightening. */
#ifndef HET_NWIN
#define HET_NWIN 128
#endif
#ifndef HET_THETA_DISTINCT
#define HET_THETA_DISTINCT 2
#endif
/* Cells (instance,run) the aggregate can hold.  NUMBER_OF_RUN is 10 by default;
   a campaign that exceeds this is TRUNCATED and says so (HET_ST_CELLS_TRUNCATED)
   rather than silently scoring a subset. */
#ifndef HET_STATS_MAX_CELLS
#define HET_STATS_MAX_CELLS 128
#endif
/* ---------------------------------------------------------------------------
 * HET_P_MIN -- the run-level hit-rate of the HARDEST het behaviour we have actually
 * OBSERVED on our own harness.  It sizes the campaign (het_budget_runs below): run
 * enough near-independent cells that, HAD the target's rate equalled the hardest
 * behaviour we CAN see, we would have had a 95% chance to catch it.  A null after that
 * budget means something; a null before it means we did not look hard enough.
 *
 * IT IS 0 -- UNSET -- AND IT MUST STAY THAT WAY UNTIL GH200 MEASURES IT.
 *
 * DO NOT seed it with Bagchi's ~0.2%.  On re-reading the primary PDF that number is
 * the GPU-only INTER-CTA rate (Bagchi 5.1 p.74, attributed to their 4.1 results, where
 * producer and consumer are both GPU threads on different CTAs): it fires with NO CPU
 * participation and WITHOUT crossing C2C.  There is no published numeric het hit-rate
 * anywhere in that paper -- Table 4 is qualitative.  Sizing the whole campaign off it
 * would be sizing it off a different experiment on a different interconnect.
 *
 * The het p_min is HARDWARE-ONLY, and B6c already hands us the population to derive it
 * from: the ALLOWED-OBSERVED rows ARE the observed-rate sample, and ALLOWED-UNOBSERVED
 * marks the shapes that are too hard.  Until then p_min is a SYMBOL, not a number, and
 * het_budget_runs() returns "NOT SIZED" rather than inventing one. */
#ifndef HET_P_MIN
#define HET_P_MIN 0.0
#endif

/* Above this the NB fit is numerically Poisson (r -> inf; see het_mu_upper). */
#define HET_R_POISSON 1e9
/* c(0.05) for the asymptotic two-sample Kolmogorov-Smirnov critical value. */
#define HET_KS_C05 1.358
/* Report threshold only: at or above this F_win the bound has WIDENED enough
   that the reader must be told the rule of three no longer applies. */
#define HET_BURSTY_F 2.0

/* ---------------------------------------------------------------------------
 * B7c -- WHEN IS tau ITSELF TRUSTWORTHY?  An integrated autocorrelation time is
 * estimated from a finite series, and the estimate is worthless unless the series
 * is long compared with the very quantity it is estimating.  The standard rule of
 * thumb, from the emcee autocorrelation tutorial (Foreman-Mackey et al., "emcee:
 * The MCMC Hammer", PASP 125:306, 2013; docs at emcee.readthedocs.io):
 *
 *     "you probably shouldn't trust any estimate of tau unless you have more
 *      than F x tau samples for some F >= 50"
 *
 * emcee treats this as a HARD ERROR, not a warning: integrated_time(tol=50) raises
 * AutocorrError -- "The chain is shorter than {0} times the integrated
 * autocorrelation time ... Use this estimate with caution and run a longer chain!"
 * -- and its tol default IS 50 ("the minimum number of autocorrelation times needed
 * to trust the estimate").  Stan's ESS guidance is the same family.
 *
 * DIVERGENCE FROM THE CITED SOURCE, DISCLOSED (this matters, and it is why the
 * guard below fixes the THRESHOLD and not the direction).  emcee's estimator is
 * SOKAL AUTOMATIC WINDOWING; ours (het_tau_ips) is GEYER'S INITIAL POSITIVE
 * SEQUENCE, which truncates at the first non-positive pair.  The two fail in
 * OPPOSITE directions on a short series: emcee's docs report theirs going
 * "dangerously over-confident" on short chains, whereas Geyer IPS is MEASURED here
 * to UNDER-read tau -- a noisy short stream throws up a spurious non-positive pair,
 * the sum is cut off early, and tau comes back far below both the truth AND the
 * HET_NWIN ceiling (so HET_ST_TAU_AT_CAP never fires).  An under-read tau
 * OVER-credits N_eff and makes the false-negative bound TIGHTER THAN THE TRUTH --
 * the one direction every clamp in this file exists to forbid.  Measured on an
 * AR(1)-rate/Poisson-count control stream at the shipped configuration (R = 10,
 * HET_NWIN = 128): true tau 181, het_tau_ips 53.8, N_eff credited 2.4 against an
 * honest 1.0 -- a 2.4x over-credit that nothing flagged.
 *
 * So we import the RELIABILITY THRESHOLD (F >= 50), which is estimator-independent,
 * and NOT emcee's bias direction, which is not.  Below the threshold tau is NOT
 * RESOLVED and buys nothing: N_eff falls back to 1, which IS B7's reading.  A tau
 * that could not be measured must never buy a tighter bound -- exactly as a KS test
 * that could not run must never unlock P_rep (HET_ST_KS_UNDERPOWERED).
 *
 * WHAT THIS GUARD DOES *NOT* DO -- disclosed, because it bounds what may be claimed.
 * It bounds the UNRESOLVED regime; it does NOT make het_tau_ips unbiased INSIDE the
 * resolved band.  On the same AR(1)-rate/Poisson-count fixtures, tau estimates that
 * DO clear the threshold still over-credited N_eff by up to ~1.7x (true tau 17.4,
 * estimated 10.3).  That residual is (a) one-sided in the same optimistic direction,
 * (b) far smaller than the ~6x rule-of-three overclaim B7 exists to prevent and the
 * 2.4x this guard removes, and (c) bounded by the estimator's noise rather than
 * unbounded.  It is NOT corrected here: a bias correction is estimator-specific and
 * would have to be re-derived for the real GH200 control stream, whereas the
 * reliability threshold transfers.  B8 must treat an in-band N_eff as accurate to a
 * FACTOR, not to a digit, and must not build a confidence interval that assumes
 * otherwise. */
#define HET_TAU_MIN_SAMPLES 50.0

typedef enum { CONF_ROBUST, CONF_ADVISORY, CONF_EXPLORATORY } het_confidence;

/* ---------------------------------------------------------------------------
 * THE ORACLE CLASS (B6c) -- what the CMCM actually predicts for THIS test.
 *
 * Without this field the rule below had no way to know what it was looking at,
 * so it framed EVERY test as should-be-forbidden: any test that observed its
 * weak outcome printed "the should-be-FORBIDDEN outcome was OBSERVED ... A
 * single sighting REFUTES the model's prediction".  Only 16 of the 338 het
 * tests are Disallowed.  286 are oracle-ALLOWED -- for them the weak outcome is
 * EXPECTED, and observing it CONFIRMS the model is not over-strong (Iorga's
 * from-below half) -- and 36 are NO-ORACLE, where allowed-vs-forbidden is
 * itself unestablished.  So 322 of 338 harnesses stood ready to print a LOUD
 * FALSE REFUTATION of the compound memory model.  The sharpest instance:
 * MP-cg-sys-relaxed is oracle-Allowed AND is the Layer-B canary for 265 rows --
 * the one test whose entire job is to FIRE would have refuted the model by
 * doing it.
 *
 * This is the mirror image of the constant-false `_weak' detector: not a silent
 * false "Never", but a loud false refutation, on the single most consequential
 * claim the campaign can make.
 *
 * ORACLE_UNSET IS 0 ON PURPOSE.  het_obs_record is memset(0) before it is
 * filled, so the zero value is what an emitter that FORGOT this field would
 * produce.  If DISALLOWED were 0, that omission would silently restore the very
 * bug this enum exists to kill -- every un-tagged test would be framed as
 * forbidden again.  Instead the zero is a loud sentinel: het_verdict() below
 * fails CLOSED on it (COLD-INVALID + HET_DQ_ORACLE_UNSET) and claims nothing at
 * all.  Never reorder these.
 *
 * The tag is not computed here -- it is read from field 2 of
 * tests/het/control-map.csv (the grounded oracle, expected-nvidia.csv), which
 * the emitter already parses to find mu(T).  See Q4 3.3 / R5 and
 * hetlitmus/docs/positive-control.md. */
typedef enum {
  ORACLE_UNSET = 0,   /* the emitter did not tag this harness -- FAIL CLOSED */
  ORACLE_DISALLOWED,  /*  16: the CMCM FORBIDS the weak outcome.  A sighting REFUTES. */
  ORACLE_ALLOWED,     /* 286: the CMCM PERMITS it.  A sighting is the EXPECTED result
                              and is evidence the model is not OVER-STRONG.  Absence is
                              an OBSERVABILITY result, not a model result. */
  ORACLE_NONE         /*  36: NO-ORACLE -- the CMCM does not settle it (IRIW/2+2W need
                              multi-copy atomicity; WRC/ISA2/RWC need cross-device
                              A-cumulativity -- the ARM-MCA x PTX-non-MCA frontier
                              Bagchi 4.2 defers).  CHARACTERIZATION, never validation. */
} het_oracle_t;

/* ---------------------------------------------------------------------------
 * Which stress mechanisms this BUILD asked for.
 *
 * A mechanism that produced zero work is a DEAD mechanism only if it was
 * requested.  A deliberately disabled one is not a bug -- and without this
 * distinction an intentional no-stress baseline run would be classified COLD
 * forever, which is just a different way of building a rule that always says
 * the same thing.  The emitter fills this from the compile-time knobs, so the
 * verdict stays a PURE FUNCTION OF THE RECORD (and is therefore unit-testable
 * from synthetic records -- see hetlitmus/verify/verdictcheck.py). */
#define HET_REQ_GPU_STRESS  (1u << 0)   /* HET_PRE_STRESS_PCT | HET_MEM_STRESS_PCT */
#define HET_REQ_SPIN        (1u << 1)   /* HET_BARRIER_PCT -> spin_rendezvous+cap  */
#define HET_REQ_CPU_ENEMY   (1u << 2)   /* HET_CPU_ENEMIES                         */
#define HET_REQ_CPU_PRELOAD (1u << 3)   /* HET_CPU_PRELOAD_PCT && _PRELOAD_LIVE    */
#define HET_REQ_NOISE_CPU   (1u << 4)   /* HET_NOISE_CPU                           */
#define HET_REQ_NOISE_GPU   (1u << 5)   /* HET_NOISE_GPU_BLOCKS                    */

typedef struct het_obs_record {
  const char *test_name; int instance_id; int run_id;
  /* What the CMCM predicts for this test (B6c).  It selects which of the three
     REPORTING FRAMES the verdict and the printout use, and it is the difference
     between "this refutes the model" and "this is exactly what the model said
     would happen".  ORACLE_UNSET (the memset default) fails closed. */
  het_oracle_t het_oracle;
  /* MECHANISM tier: how well this test's cycle can be RECOVERED from the read
     and observer buffers (HetCond.perpetual_class).  Distinct from `reporting'
     below -- do not conflate them. */
  het_confidence confidence;
  /* REPORTING tier: what a null from this test may be CLAIMED as.  R and S are
     both mechanically `Advisory' (one ws-location + >=1 register), but R has
     ZERO rf edges -- its only read is the fr-against-init read, which in the
     WEAK case decodes to tag 0: no writer, no synchrony (B3-decision 4.2).  R
     therefore leans on the fragile observer for BOTH the synchrony point and
     the ws edge, exactly like 2+2W, so it is DEMOTED to EXPLORATORY for
     reporting.  Tiers: ROBUST 266 / ADVISORY 25 (S) / EXPLORATORY 47 (2+2W 22
     + R 25). */
  het_confidence reporting;
  uint64_t N, frames_examined;
  uint64_t target_count_exhaustive, target_count_heuristic;
  /* 0 = the O(N^T_L) exhaustive scan did NOT run at this N (capped by
     HET_EXHAUSTIVE_MAX), so target_count_exhaustive is NOT a count of zero
     observations -- it is "not measured".  Reading it as data would manufacture
     a false "Never", which is the same class of silent falsification as a
     constant-false detector.  het_verdict() below REFUSES to return
     HET_CREDIBLE_NULL when this is 0.

     NOTE the T_L<=1 case (MP/S/R/2+2W and every other shape with no windowed
     proc -- 123 of the 338 het tests, and 14 of the 16 Disallowed): there every
     frame is decoded EXACTLY, the O(N) scan is the ground truth, and this flag
     is 1 regardless of N.  Before B6 it was set to (N <= HET_EXHAUSTIVE_MAX)
     for every test, which at the default N=100000 was 0 for ALL 338 -- so the
     rule below would have called every run COLD, forever. */
  int exhaustive_valid;
  uint64_t interleavings_detected;
  uint64_t distinct_decoded_iters;
  uint64_t ws_edges_via_observer;
  uint64_t observer_unique_count;
  int32_t skew_min, skew_max; double skew_mean, skew_stddev;
  /* ---- B7: IS THE DEGENERACY GUARD APPLICABLE ON THIS TEST?  (TRAP 3.)
     distinct_decoded_iters and skew_stddev are BOTH written from the same
     synchrony-decode block, so a test with no synchrony read leaves BOTH at their
     memset zero.  Measured on the emitted corpus: 22 of the 338 -- every 2+2W, the
     store-only shape, which has no reader at all -- are in exactly that position
     (266 have a synchrony decode only, 50 have both, 22 have only the observer,
     0 have neither).  A guard that read `skew_stddev == 0' as "the decoder is
     degenerate" would therefore condemn every cell of all 22 FOREVER, making
     k_eff constant 0 and P_rep a constant 1 - e^0 = 0 on them: the fifth constant.
     This is the exhaustive_valid lesson verbatim -- 0 means NOT MEASURED, never
     "measured zero".  So the guard asks which decode channel this test HAS
     (het_cell_degenerate) instead of firing blind, and these two flags are what
     let it ask.  Set by the emitter from the instance it actually compiled. */
  int sync_valid;   /* 1 => distinct_decoded_iters + skew_* are populated  (316) */
  int obs_valid;    /* 1 => observer_unique_count is populated             ( 72) */
  /* ---- B6 POSITIVE CONTROL (Q4 3.2).  control_* = Layer A (the minimal mutant
     mu(T) of THIS test); canary_* = Layer B (the universal het MP floor).  Both
     are tallied by the SAME recovery scan as the test's own target_count, on
     disjoint cache-line-padded locations, in the same launch under the same
     stress -- a control that ran at another time, under another stress roll and
     another thermal state, certifies nothing about THIS window (Kirkham shows
     the weak-behaviour rate is not even stationary within one run, 4.3). */
  uint64_t control_target_count;
  uint64_t control_frames_examined;
  uint64_t canary_target_count;
  uint64_t canary_frames_examined;
  /* Each co-running instance has its OWN T_L class, so it has its own
     exhaustive_valid -- and mu(SB-*-sys-fence-2s) IS SB-*-sys-acqrel-2s, a T_L>=2
     shape whose exhaustive scan does not run at production N.  Its count therefore
     comes from the WINDOWED scan, whose hits are a strict subset of the exhaustive
     scan's under the same predicate: a windowed hit is a genuine recovered cycle
     (it can MISS cycles, it cannot invent them), so it UNDER-counts the control,
     which errs toward COLD -- the safe direction.  These flags say which kind of
     count you are reading; het_verdict() deliberately does NOT gate the control on
     them, because a control that cannot fire is not a control (B6b). */
  int control_exhaustive_valid;
  int canary_exhaustive_valid;
  /* ---- B7 PER-WINDOW SUB-TALLIES OF THE CONTROL CHANNEL (Q3 6.3).
     The run's frames are bucketed into HET_NWIN windows and each control sighting
     is tallied into the window its frame fell in.  These are the ONLY within-run
     time series the record carries, and every dispersion/stationarity estimate in
     the statistics layer is computed from them:
        F_win   Var/Mean over the (run,window) samples  -> the NB dispersion r_hat
        acf1    lag-1 autocorrelation                   -> diagnostic
        KS      first-20%-of-windows vs last-10%        -> stationarity
     The CONTROL, never the target: the target is far too rare to estimate a
     variance from (that is the entire reason it needs a bound at all), while the
     control is the high-rate proxy riding the SAME fabric in the SAME run under
     the SAME stress (Q3 3.3, job 3: "the positive control is not just a hot/cold
     light -- it is the instrument that measures the exact statistical corrections
     2 says are needed").
     They are bumped on the same line, under the same predicate, as
     control_target_count / canary_target_count -- so
         sum(control_win[]) == control_target_count
     is an INVARIANT, and the statistics layer checks it on every cell
     (HET_ST_WIN_DESYNC).  That is what makes these tallies self-proving at run
     time on real hardware: if the bump were dead-code-eliminated or mis-indexed
     the sum would not match the total, and a mechanism that cannot be observed to
     be alive must be assumed dead. */
  uint32_t control_win[HET_NWIN];
  uint32_t canary_win[HET_NWIN];
  /* 1 - e^{-control_target_count} (Kirkham's reproducibility score).
     *** DO NOT USE THIS AS A CONFIDENCE.  IT IS A HOTNESS INDICATOR ONLY. ***
     control_target_count is a count of validated FRAMES, and the recovery scan
     validates N^{T_L} overlapping frames per N iterations (PerpLE VI-B.1: "the
     number of frames is polynomial in the number of iterations").  Frames are
     therefore NOT independent Bernoulli trials, and feeding their count into
     1 - e^{-n} drives it to 1 VACUOUSLY -- not because the behaviour reproduces,
     but because the frame combinatorics inflate n.  PerpLE never makes that
     mistake (it uses frames as a THROUGHPUT metric, never as confidence).
     B7's het_stats_compute lifts the replication unit to the (instance,run) cell,
     Y = 1[target_count >= 1], and reports P_rep from THAT.  This field survives
     only as the hot/cold light het_print_liveness prints. */
  double control_Prep;
  /* 0 => NO Layer-A mutant was compiled into this harness, so
     control_target_count is structurally zero and means NOTHING.  1 => a real
     mu(T) is genuinely CO-RUNNING here, in the same launch, under the same
     stress, on the same C2C path (B6b: the multi-instance emitter).

     THIS FLAG IS STILL 1 ON EXACTLY THE 16 DISALLOWED TESTS, and B6c did not
     widen it.  Only a should-be-forbidden test HAS a minimal mutant (a mutant
     presupposes a known-forbidden cycle to weaken -- MC-Mutants 1.2, Q4 4.2),
     so the other 322 have no Layer A and never will.  What B6c added them is a
     Layer-B canary, and that is a DIFFERENT flag below -- because "the canary is
     co-running" and "the mutant is co-running" are different claims, and
     collapsing them into one bit is how a null on a test with no mutant would
     start reading as vouched-for. */
  int control_compiled_in;
  /* 0 => no Layer-B canary is co-running, so canary_target_count is structurally
     zero and means NOTHING.  1 => a real canary instance is in this launch.

     BEWARE canary_name: it is non-NULL on tests that do NOT co-run a canary (the
     map NAMES a canary for all 338).  A NAME IS NOT A CO-RUN.  This flag, and
     only this flag, says the instance is actually there -- it is set from the
     emitted instance POPULATION, not from the map.

     It is 0 on exactly two tests: MP-{cg,gc}-sys-relaxed, which ARE the canary
     (control-map.csv says `self') and cannot co-run themselves.  They are their
     own liveness signal: if the most-observable het shape fires, the path is
     alive; if it does not, nothing in this harness can say the harness was hot,
     and het_verdict() correctly returns COLD-INVALID rather than inventing a
     result.  That is not a gap -- it IS the definition of a cold harness. */
  int canary_compiled_in;
  const char *control_name;   /* mu(T), from tests/het/control-map.csv */
  const char *canary_name;    /* the Layer-B canary (NAMED for all 338 -- see above) */
  /* B4-fix STRESS LIVENESS.  The stress layer is invisible to the L0
     faithfulness gate by design, so its health has to be MEASURED at run time or
     it is not known at all (it was inert for two commits and every gate stayed
     green).  spin_rendezvous/spin_cap: how the window-opener's spins ended -- a
     mostly-cap-released spin is a delay loop, not a rendezvous, and B8 tunes
     HET_BARRIER_PCT against this ratio.  stress_truncated: stress lanes that hit
     HET_STRESS_MAX_ROUNDS, i.e. stopped stressing while the test was still
     running -- such a run's non-observations are NOT comparable with a stressed
     run's, so it is DISQUALIFYING, not cosmetic.

     gpu_stress_rounds (B6b): the max rounds any single het_do_stress call
     completed.  B6a had NO such counter and said so plainly: the record could not
     tell whether the GPU scratchpad loop had EXECUTED, so the rule refused to
     disqualify on HET_REQ_GPU_STRESS ("a check that cannot fail is worse than no
     check").  It can now, and it must: a co-run harness reserves 3x-5x the test
     blocks, so an empty stress population -- the code present, requested, and run
     by nobody -- is exactly the regression B6b makes plausible. */
  uint64_t spin_rendezvous, spin_cap, stress_truncated;
  uint64_t gpu_stress_rounds;
  /* B5 CPU + INTERCONNECT LIVENESS.  Same argument as the B4 block above, for the
     two levers B4 did not have.  Every field is here because the mechanism it
     measures has a plausible way to die silently:
       cpu_enemy_rounds  0 => the CPU enemies never ran (stress_go ordering, or a
                         loop the optimiser deleted).
       cpu_preload_ops   0 => the M3 incantation is inert (a host with no cache
                         primitives, or a 0% roll).
       noise_cpu_rounds  0 => the Grace half of the C2C noise never ran;
       noise_gpu_blocks  0 => the Hopper half never ran.  Either way the run is NOT
                         interconnect-stressed, whatever HET_NOISE_* claimed.
       cpu_aff_failures >0 => sched_setaffinity FAILED: the threads are wherever the
                         scheduler put them and the pinning is fiction.
       place_failures   >0 => cudaMemAdvise was REFUSED: HET_PLACE placed nothing.
     A target count from a run whose stress was inert is not the same datum as one
     from a stressed run, and nothing else in this record would say so. */
  uint64_t cpu_enemy_rounds, cpu_enemy_accesses, cpu_preload_ops;
  uint64_t noise_cpu_rounds, noise_cpu_words;
  uint32_t noise_gpu_blocks, noise_gpu_rounds;
  uint32_t cpu_enemies, cpu_aff_failures, place_failures;
  /* The two knobs B8 tunes the interconnect lever against, carried per run so the
     autotuner reads what the run REALISED rather than what it asked for.  ws_mb is
     the noise WORKING SET, and it is the knob that decides whether the noise crosses
     anything at all: below the last-level cache (Grace L3 = 114 MB) the buffer is
     served from cache and generates no interconnect traffic, so a config that scores
     well at 8 MB scored a stressor that was not running. */
  uint32_t noise_ws_mb, place_mode;
  /* The window resolution this run REALISED (= HET_NWIN of the binary that
     produced it).  Same rule as noise_ws_mb/place_mode above: B8 and the B7b
     campaign scheduler read what the run actually did, not what a build was
     asked for -- HET_NWIN is swept, and a record scored at one resolution must
     never be silently pooled with a record scored at another (tau_w and F_win
     are resolution-dependent; N_eff's clamp ceiling IS nwin). */
  uint32_t nwin;
  uint32_t stress_requested;    /* HET_REQ_* bitmask -- see above */
} het_obs_record;

/* B7 PRODUCER SIDE.  Frame index -> window bucket, called from the recovery scan on
   the SAME line as the control's count bump.  It is a function of the frame index,
   so -- unlike a -D knob threaded through an if-chain, which is how B4's stress layer
   came to be silently deleted -- there is nothing here for the optimiser to fold: the
   bucket cannot be known at compile time.  Clamped rather than asserted: an
   out-of-range bucket must not corrupt the record, and the sum-vs-total invariant in
   het_stats_compute would catch a mis-index anyway. */
static int het_win_of(long f, long n) {
  long w;
  if (n <= 0) return 0;
  w = (f * (long)HET_NWIN) / n;
  if (w < 0) w = 0;
  if (w >= HET_NWIN) w = HET_NWIN - 1;
  return (int)w;
}

/* ---------------------------------------------------------------------------
 * RUNTIME knobs (B7b).  getenv, never a -D the device code can see: a
 * compile-time constant threaded through an if-chain is exactly how B4's
 * stress layer came to be silently deleted (nvcc folds the knob and removes
 * the only branch with side effects).  These are HOST-side reads the campaign
 * scheduler (hetlitmus/campaign.py) retunes per invocation without a rebuild:
 *
 *   HET_RUNS_MAX   run at most this many runs this invocation (clamped to the
 *                  compiled NUMBER_OF_RUN -- the record array is that size;
 *                  GROWING R happens by re-invoking with a fresh HET_SEED)
 *   HET_ADAPTIVE   1 => consult het_campaign_should_stop() after every run
 *   HET_P_GOAL     stop a bound-needing test once p_bound <= this (unset/<=0
 *                  => never bound-stop; run to budget)
 *   HET_SEED       overrides the compiled HET_SEED base.  THE SCHEDULER MUST
 *                  VARY THIS PER INVOCATION: re-running the same seeds adds no
 *                  fresh phase/seed draws, and pooling two such invocations as
 *                  2R independent cells would silently double-count R_eff.
 *
 * Unset => the compiled default, so a bare ./run is byte-for-byte the B7
 * behaviour. */
static long het_env_long(const char *name, long dflt) {
  const char *v = getenv(name);
  char *end;
  long x;
  if (v == NULL || *v == '\0') return dflt;
  x = strtol(v, &end, 0);
  return (end == v) ? dflt : x;
}
static double het_env_double(const char *name, double dflt) {
  const char *v = getenv(name);
  char *end;
  double x;
  if (v == NULL || *v == '\0') return dflt;
  x = strtod(v, &end);
  return (end == v) ? dflt : x;
}

/* ---------------------------------------------------------------------------
 * The verdict.  THREE REPORTING FRAMES, ONE PER ORACLE CLASS (B6c) -- because
 * "we saw the weak outcome" means three completely different things depending on
 * what the model predicted, and until B6c the rule knew only the first one.
 *
 * ORACLE_DISALLOWED (16) -- the model FORBIDS it; the null is the evidence.
 *   HET_MISMATCH        the Disallowed outcome was OBSERVED.  A single sighting
 *                       REFUTES the CMCM prediction.  Falsification is one-sided,
 *                       so NO control is needed to believe a positive -- this is
 *                       the scientifically most valuable outcome and it is
 *                       reported loudly and unconditionally.
 *   HET_CREDIBLE_NULL   not observed, and the harness was demonstrably hot ON
 *                       THIS MACHINERY: mu(T) fired >= tau_hot on the same run,
 *                       and T's own two engines provably overlapped.
 *   HET_WEAK_NULL       not observed; the cross-device path is alive (the canary
 *                       fired, or mu(T) fired but the ground-truth scan did not
 *                       run) but we cannot independently confirm the harness
 *                       reaches T's specific interleaving.  Escalate stress
 *                       tuning for T's shape (B8).
 *
 * ORACLE_ALLOWED (286) -- the model PERMITS it; the SIGHTING is the evidence.
 *   HET_ALLOWED_OBSERVED    the permitted weak outcome fired.  This is the
 *                       EXPECTED result and it is Iorga's from-below half: it is
 *                       evidence the CMCM is not OVER-STRONG (4.4, the pairing
 *                       "disallowed-never-seen AND allowed-sometimes-seen under
 *                       the same stress").  It is NOT a refutation of anything.
 *                       No control is needed and none is used: a firing Allowed
 *                       test IS ITS OWN CONTROL.
 *   HET_ALLOWED_UNOBSERVED  permitted, but we could not expose it on this
 *                       hardware under this stress, on a harness the canary shows
 *                       was HOT.  This is an OBSERVABILITY result, NOT a model
 *                       result -- it says nothing whatever about the CMCM.  It is
 *                       Iorga's observability taxonomy (4.4: inter-channel 3/3
 *                       observed, request-pool 1/3, response-order 0/4) and
 *                       Alglave's GTX-280 honesty (fn.7 p.577).  It feeds B8's
 *                       stress-tuning priority.
 *
 * ORACLE_NONE (36) -- the model is SILENT; there is nothing to validate.
 *   HET_CHARACTERIZED   the observed behaviour, reported AGAINST THE CANARY RATE,
 *                       as characterization: "under a harness where the MP canary
 *                       fired n times, GH200 exhibited outcome Y in Z% of frames".
 *                       NEVER "refutes", NEVER "confirms", NEVER "forbidden" --
 *                       there is no prediction to confirm or refute (Q4 R5).
 *
 * ALL CLASSES
 *   HET_COLD_INVALID    the harness was NOT demonstrably hot.  The empty
 *                       histogram carries NO information.  DISCARD the null; do
 *                       NOT report it as "not observed".  This is the run a
 *                       naive harness would silently mis-report as a pass.  It
 *                       stays reachable for ALL THREE classes on purpose: a
 *                       characterization of a dead harness is not a finding, and
 *                       a class whose verdict is a CONSTANT is exactly the bug
 *                       this file keeps being written to prevent.
 * ------------------------------------------------------------------------- */
typedef enum {
  HET_MISMATCH = 0,
  HET_CREDIBLE_NULL,
  HET_WEAK_NULL,
  HET_COLD_INVALID,
  HET_ALLOWED_OBSERVED,
  HET_ALLOWED_UNOBSERVED,
  HET_CHARACTERIZED
} het_verdict_t;

/* Why a run was DISQUALIFIED (its null is discarded).  Each names a mechanism
   that is DEAD, not merely suboptimal. */
#define HET_DQ_NO_CONTROL_BUILT (1u << 0)  /* no control compiled in (B6a)        */
#define HET_DQ_NO_INTERLEAVING  (1u << 1)  /* the two engines never overlapped    */
#define HET_DQ_CONTROLS_COLD    (1u << 2)  /* neither mu(T) nor the canary fired  */
#define HET_DQ_STRESS_TRUNCATED (1u << 3)  /* stress stopped mid-run              */
#define HET_DQ_SPIN_DEAD        (1u << 4)  /* window-opener requested, never spun */
#define HET_DQ_CPU_ENEMY_DEAD   (1u << 5)
#define HET_DQ_CPU_PRELOAD_DEAD (1u << 6)
#define HET_DQ_NOISE_CPU_DEAD   (1u << 7)  /* NOT interconnect-stressed           */
#define HET_DQ_NOISE_GPU_DEAD   (1u << 8)
#define HET_DQ_GPU_STRESS_DEAD  (1u << 9)  /* het_do_stress requested, never ran  */
/* The emitter did not tag this harness with its oracle class (B6c).  The rule
   then does not know whether a sighting REFUTES the model or CONFIRMS it, so it
   must claim NOTHING.  Fail closed, loudly. */
#define HET_DQ_ORACLE_UNSET     (1u << 10)

/* Why a null was CAVEATED (still reportable, but weaker than it looks). */
#define HET_CV_NO_EXHAUSTIVE    (1u << 0)  /* ground-truth scan did not run       */
#define HET_CV_CANARY_ONLY      (1u << 1)  /* Layer B fired, Layer A did not      */
#define HET_CV_HEURISTIC_SIGHT  (1u << 2)  /* sighting via the windowed heuristic */
#define HET_CV_AFF_FAILED       (1u << 3)  /* pinning is fiction                  */
#define HET_CV_PLACE_REFUSED    (1u << 4)  /* cudaMemAdvise placed nothing        */
#define HET_CV_SPIN_CAP         (1u << 5)  /* a delay loop, not a rendezvous      */
#define HET_CV_UNSTRESSED       (1u << 6)  /* no stress requested at all          */

static int het_dead(uint32_t req, uint32_t bit, uint64_t rounds) {
  return (req & bit) && rounds == 0;
}

/* The rule.  Q4 3.3, plus the exhaustive_valid gate (Item E.1) and the B4/B5
   liveness disqualifiers.  A PURE function of the record. */
static het_verdict_t het_verdict(const het_obs_record *r,
                                 uint32_t *dq_out, uint32_t *cv_out) {
  uint32_t dq = 0, cv = 0;
  uint32_t req = r->stress_requested;
  het_verdict_t v;
  int hot_control, hot_canary;

  /* Each layer is gated on ITS OWN compiled-in flag (B6c).  hot_canary used to be
     gated on control_compiled_in -- correct while the ONLY co-run harnesses were
     the 16 that had both, and silently wrong the moment a harness co-runs a canary
     WITHOUT a mutant, which is now 320 of the 338. */
  hot_control = (r->control_compiled_in && r->control_target_count >= HET_TAU_HOT);
  hot_canary  = (r->canary_compiled_in  && r->canary_target_count  >= HET_TAU_HOT);

  /* ---- 0. FAIL CLOSED ON AN UNTAGGED HARNESS (B6c).  Before anything else: if we
     do not know what the model predicts for this test, we cannot know what an
     observation MEANS, and every sentence we could print would be a guess.  Claim
     nothing.  (This is reachable only via an emitter bug -- the 338 are tagged from
     control-map.csv -- which is exactly why it must be a hard, visible stop rather
     than a default that quietly picks a frame.) */
  if (r->het_oracle == ORACLE_UNSET) {
    if (dq_out) *dq_out = HET_DQ_ORACLE_UNSET;
    if (cv_out) *cv_out = 0;
    return HET_COLD_INVALID;
  }

  /* ---- 1. THE CAVEATS ARE COMPUTED FIRST, BECAUSE A MISMATCH NEEDS THEM TOO.
     (B6b fix.)  They used to be computed BELOW the MISMATCH return, so the single
     most valuable outcome the campaign can produce -- an observed weak behaviour
     that REFUTES the CMCM -- was reported with no record of the stress config it
     was observed under.  An unreproducible sighting is a much weaker result than a
     reproducible one, and Alglave requires the incantations to travel with it:

         "we report the number of times the weak behaviour was observed out of
          the total number of runs, together with the configuration of the
          stress ... so that our results can be reproduced."
                                        -- Alglave et al., ASPLOS'15, 4.3.

     The verdict is unchanged (a sighting is a sighting); what changes is that its
     PROVENANCE now travels with it. */
  if (!r->exhaustive_valid)         cv |= HET_CV_NO_EXHAUSTIVE;
  /* "Layer B fired, Layer A did not" is only a MEANINGFUL caveat where a Layer A
     exists to have not fired.  Without the control_compiled_in guard this would be
     raised on all 322 non-Disallowed tests -- which have no mutant BY CONSTRUCTION
     -- turning a real diagnostic ("this shape's window was not hit; escalate stress
     tuning") into a line of boilerplate that fires on 95% of the corpus and so
     tells a reader nothing. */
  if (r->control_compiled_in && !hot_control && hot_canary)
                                    cv |= HET_CV_CANARY_ONLY;
  if (r->cpu_aff_failures > 0)      cv |= HET_CV_AFF_FAILED;
  if (r->place_failures > 0)        cv |= HET_CV_PLACE_REFUSED;
  if (req == 0)                     cv |= HET_CV_UNSTRESSED;
  { uint64_t spins = r->spin_rendezvous + r->spin_cap;
    if (spins && r->spin_rendezvous * 2 < spins) cv |= HET_CV_SPIN_CAP; }

  /* ---- 2. A SIGHTING.  Believed unconditionally -- no control is needed to
     believe a POSITIVE, and an inert-stress run that nevertheless SAW the outcome
     still saw it.  Falsification (and confirmation-from-below) are one-sided.

     WHAT THE SIGHTING MEANS, HOWEVER, IS ENTIRELY THE ORACLE'S CALL (B6c), and
     this is the branch that was backwards.  It returned MISMATCH -- "the
     should-be-FORBIDDEN outcome was OBSERVED ... a single sighting REFUTES the
     model" -- for EVERY test, when 322 of the 338 are not forbidden at all.  For
     an oracle-ALLOWED test the very same sighting is the model working exactly as
     specified, and the loud refutation was a false alarm on the most consequential
     claim the campaign can make.

     ON THE HEURISTIC COUNT -- a deliberate, disclosed strengthening of the
     literal rule in Q4 3.3, which keys MISMATCH off target_count_exhaustive
     alone.  For a T_L>=2 shape at production N the exhaustive scan does not run
     (HET_EXHAUSTIVE_MAX), so target_count_exhaustive is 0 BY CONSTRUCTION and a
     real sighting would be silently dropped -- a false negative on the single
     most valuable outcome we can produce.  The windowed heuristic searches
     [c-W, c+W] and the exhaustive scan searches [0, N-1] with the SAME
     predicate, so the heuristic's hits are a SUBSET of the exhaustive scan's:
     a heuristic hit is a genuine recovered cycle (it can miss cycles, it cannot
     invent them).  Counting it is therefore sound and strictly safer.  It is
     flagged HET_CV_HEURISTIC_SIGHT so the report never passes it off as
     ground truth. */
  if (r->target_count_exhaustive > 0 || r->target_count_heuristic > 0) {
    if (r->target_count_exhaustive == 0) cv |= HET_CV_HEURISTIC_SIGHT;
    if (dq_out) *dq_out = 0;
    if (cv_out) *cv_out = cv;
    switch (r->het_oracle) {
    case ORACLE_DISALLOWED: return HET_MISMATCH;         /* REFUTES the model    */
    case ORACLE_ALLOWED:    return HET_ALLOWED_OBSERVED; /* the EXPECTED result  */
    default:                return HET_CHARACTERIZED;    /* the model is SILENT  */
    }
  }

  /* ---- 3. Liveness: is this run's null even a datum?
     "A null from an inert-stress run is not the same datum as a null from a
     stressed run, and nothing else in the record would say so." */
  /* NEITHER layer is co-running => this harness has no liveness evidence of any
     kind, whatever its counters say.  (B6c: this used to be `!control_compiled_in',
     which after the canary co-run would have disqualified all 320 canary-only
     harnesses -- every Allowed and NO-ORACLE null COLD forever, i.e. a rule that
     always says the same thing.  It is now "no control AND no canary", which is
     true of exactly two tests: MP-{cg,gc}-sys-relaxed, which ARE the canary.) */
  if (!r->control_compiled_in && !r->canary_compiled_in)
                                                  dq |= HET_DQ_NO_CONTROL_BUILT;
  if (r->interleavings_detected == 0)             dq |= HET_DQ_NO_INTERLEAVING;
  if (r->stress_truncated > 0)                    dq |= HET_DQ_STRESS_TRUNCATED;
  /* The window-opener: requested via HET_BARRIER_PCT, evidenced by the spin
     tally.  Zero spins across an entire run means it never ran. */
  if (het_dead(req, HET_REQ_SPIN, r->spin_rendezvous + r->spin_cap))
                                                  dq |= HET_DQ_SPIN_DEAD;
  /* THE GPU SCRATCHPAD STRESS (B6b).  B6a had to leave this unchecked and said so:
     het_do_stress had NO runtime tally, so the record could not say whether the
     loop EXECUTED -- only stresscheck.py could say (structurally) that it had
     survived into the PTX.  Checking it against the spin counters, which measure a
     different mechanism, would have looked like a check while proving nothing, and
     a check that cannot fail is worse than no check.  het_stress.cuh now counts
     het_do_stress rounds (HET_TALLY_STRESS_ROUNDS), so the check is real.

     The two checks are NOT redundant, and that is the whole lesson of B4: this one
     proves the loop RAN; stresscheck.py proves it still CONTAINS its scratchpad
     accesses and that they are invariant under the -D pattern knobs (which is what
     makes them undeletable).  B4's layer was in the source, gone from the PTX, and
     green on every gate -- neither check alone would have caught it. */
  if (het_dead(req, HET_REQ_GPU_STRESS,  r->gpu_stress_rounds))
                                                  dq |= HET_DQ_GPU_STRESS_DEAD;
  if (het_dead(req, HET_REQ_CPU_ENEMY,   r->cpu_enemy_rounds))
                                                  dq |= HET_DQ_CPU_ENEMY_DEAD;
  if (het_dead(req, HET_REQ_CPU_PRELOAD, r->cpu_preload_ops))
                                                  dq |= HET_DQ_CPU_PRELOAD_DEAD;
  if (het_dead(req, HET_REQ_NOISE_CPU,   r->noise_cpu_rounds))
                                                  dq |= HET_DQ_NOISE_CPU_DEAD;
  if (het_dead(req, HET_REQ_NOISE_GPU,   (uint64_t)r->noise_gpu_blocks))
                                                  dq |= HET_DQ_NOISE_GPU_DEAD;

  /* ---- 4. Was the harness hot?  (hot_control / hot_canary were computed at the
     top, because the caveat block above needs them.) */
  if (!hot_control && !hot_canary)                dq |= HET_DQ_CONTROLS_COLD;

  /* ---- 5. The verdict.  NOT OBSERVED -- and what that is worth depends entirely
     on what the model predicted (B6c). */
  if (dq) {
    v = HET_COLD_INVALID;
  } else switch (r->het_oracle) {

  case ORACLE_DISALLOWED:
    /* The null IS the evidence, so it has to be earned. */
    if (hot_control && r->exhaustive_valid) {
      /* mu(T) -- the minimal mutant of THIS test -- fired reproducibly on the same
         run, the same stress and the same C2C path, and T's own two engines
         provably overlapped.  The harness demonstrably produced the precise
         cross-device interleaving that T's ordering is claimed to prevent. */
      v = HET_CREDIBLE_NULL;
    } else {
      /* Either only the canary fired (the C2C path is alive, but we cannot confirm
         we reach THIS shape's window -- escalate stress tuning, B8), or the
         ground-truth scan never ran, so the zero is not a measured zero. */
      v = HET_WEAK_NULL;
    }
    break;

  case ORACLE_ALLOWED:
    /* The model PERMITS this outcome and we did not see it, on a harness the canary
       shows was hot.  That is a statement about GH200 and about our stress -- NOT
       about the CMCM, which is not challenged by it in either direction.  Reporting
       it as any kind of "null" for the model would be the same error as the false
       refutation, wearing the opposite hat. */
    v = HET_ALLOWED_UNOBSERVED;
    break;

  default:
    /* NO-ORACLE.  There is no prediction, so there is nothing to confirm, refute,
       or call a null.  Report the behaviour against the canary rate (Q4 R5).  Note
       this arm is reached BOTH when the outcome fired (branch 2 above) and when it
       did not: "GH200 exhibited it in 0 of N frames on a demonstrably hot harness"
       is itself the characterization.  What it is NOT reachable from is a COLD
       harness -- that is caught by dq above, because characterizing a dead harness
       is not a finding, it is a fabrication. */
    v = HET_CHARACTERIZED;
    break;
  }

  if (dq_out) *dq_out = dq;
  if (cv_out) *cv_out = cv;
  return v;
}

static const char *het_verdict_name(het_verdict_t v) {
  switch (v) {
  case HET_MISMATCH:           return "MISMATCH";
  case HET_CREDIBLE_NULL:      return "CREDIBLE-NULL";
  case HET_WEAK_NULL:          return "WEAK-NULL";
  case HET_ALLOWED_OBSERVED:   return "ALLOWED-OBSERVED";
  case HET_ALLOWED_UNOBSERVED: return "ALLOWED-UNOBSERVED";
  case HET_CHARACTERIZED:      return "CHARACTERIZED";
  default:                     return "COLD-INVALID";
  }
}

static const char *het_oracle_name(het_oracle_t o) {
  switch (o) {
  case ORACLE_DISALLOWED: return "Disallowed";
  case ORACLE_ALLOWED:    return "Allowed";
  case ORACLE_NONE:       return "NO-ORACLE";
  default:                return "UNSET";
  }
}

static const char *het_conf_name(het_confidence c) {
  switch (c) {
  case CONF_ROBUST:    return "ROBUST";
  case CONF_ADVISORY:  return "ADVISORY";
  default:             return "EXPLORATORY";
  }
}

static void het_obs_record_print(FILE *_ch, const het_obs_record *_r) {
  fprintf(_ch,
    "HetObs %s oracle=%s inst=%d run=%d conf=%d report=%d N=%llu frames=%llu target=%s%llu/%llu "
    "interleavings=%llu distinct_iters=%llu ws_via_obs=%llu obs_unique=%llu "
    "skew=[%d,%d] mean=%.3f sd=%.3f ctrl=%s%llu/%llu canary=%s%llu/%llu Prep=%.6f built=%d/%d "
    "spin=%llu/%llu stress_trunc=%llu do_stress_rounds=%llu req=0x%x "
    "enemies=%u enemy_rounds=%llu enemy_acc=%llu preload=%llu "
    "noise_cpu=%llu/%lluw noise_gpu=%u/%u noise_ws=%uMB place=%u nwin=%u "
    "aff_fail=%u place_fail=%u\n",
    /* oracle= is FIRST-CLASS in the machine-readable line: B7 aggregates these
       records into (instance, run) units, and Y = 1[target_count >= 1] means the
       OPPOSITE thing for an Allowed test (expected to fire) and a Disallowed one
       (expected not to).  A row that does not carry its oracle class cannot be
       pooled with anything. */
    _r->test_name, het_oracle_name(_r->het_oracle),
    _r->instance_id, _r->run_id,
    (int)_r->confidence, (int)_r->reporting,
    (unsigned long long)_r->N, (unsigned long long)_r->frames_examined,
    _r->exhaustive_valid ? "" : "NA:",
    (unsigned long long)_r->target_count_exhaustive,
    (unsigned long long)_r->target_count_heuristic,
    (unsigned long long)_r->interleavings_detected,
    (unsigned long long)_r->distinct_decoded_iters,
    (unsigned long long)_r->ws_edges_via_observer,
    (unsigned long long)_r->observer_unique_count,
    _r->skew_min, _r->skew_max, _r->skew_mean, _r->skew_stddev,
    /* "NA:" = this count came from the WINDOWED scan, not the ground-truth one.
       It is still a real count of real recovered cycles -- it just under-counts. */
    _r->control_exhaustive_valid ? "" : "NA:",
    (unsigned long long)_r->control_target_count,
    (unsigned long long)_r->control_frames_examined,
    _r->canary_exhaustive_valid ? "" : "NA:",
    (unsigned long long)_r->canary_target_count,
    (unsigned long long)_r->canary_frames_examined,
    _r->control_Prep, _r->control_compiled_in, _r->canary_compiled_in,
    (unsigned long long)_r->spin_rendezvous,
    (unsigned long long)_r->spin_cap,
    (unsigned long long)_r->stress_truncated,
    (unsigned long long)_r->gpu_stress_rounds,
    _r->stress_requested,
    _r->cpu_enemies,
    (unsigned long long)_r->cpu_enemy_rounds,
    (unsigned long long)_r->cpu_enemy_accesses,
    (unsigned long long)_r->cpu_preload_ops,
    (unsigned long long)_r->noise_cpu_rounds,
    (unsigned long long)_r->noise_cpu_words,
    _r->noise_gpu_blocks, _r->noise_gpu_rounds,
    _r->noise_ws_mb, _r->place_mode, _r->nwin,
    _r->cpu_aff_failures, _r->place_failures);
}

/* ---------------------------------------------------------------------------
 * THE REPORTING CONTRACT (Q4 5): NEVER PRINT A BARE "Never".
 *
 * Every null is printed PAIRED with the control that vouches for it, with
 * absolute numbers, so a reader can recalibrate the bar instead of taking our
 * word for it (Alglave 4.3: absolute numbers over N runs + the tuned config).
 * The two halves of the model verdict come from the same run, Iorga-style
 * (4.4): Disallowed-never-observed = the CMCM is not OVER-PERMISSIVE;
 * Allowed-sometimes-observed (the controls) = it is not OVER-STRONG.
 *
 * Where a shape's control cannot be made hot, we say so plainly rather than
 * quietly reporting the null anyway -- the GTX-280 precedent:
 *
 *     "In fairness to the authors of [19], we were unable to observe weak
 *      behaviours using our method on the Nvidia GTX 280 chip they used."
 *        -- Alglave et al., ASPLOS'15, footnote 7, p.577.
 * ------------------------------------------------------------------------- */
/* The stress-provenance caveats.  Printed for a MISMATCH as well as a null: a weak
   behaviour observed under a stress config nobody recorded is not reproducible, and
   an unreproducible refutation is a much weaker result than a reproducible one. */
static void het_print_caveats(FILE *_ch, const het_obs_record *_r, uint32_t cv) {
  if (cv & HET_CV_UNSTRESSED)
    fprintf(_ch, "  CAVEAT: no stress was requested.  Kirkham (6.2) exposed only "
                 "ONE of six mutants with no stress -- an unstressed null is weak "
                 "evidence whatever the controls say.\n");
  if (cv & HET_CV_SPIN_CAP)
    fprintf(_ch, "  CAVEAT: the window-opener released on the deadlock cap in most "
                 "spins -- it is a delay loop, not a rendezvous.\n");
  if (cv & HET_CV_AFF_FAILED)
    fprintf(_ch, "  CAVEAT: %u sched_setaffinity call(s) FAILED -- the pinning is "
                 "fiction and the stress topology is not the one being tuned.\n",
            _r->cpu_aff_failures);
  if (cv & HET_CV_PLACE_REFUSED)
    fprintf(_ch, "  CAVEAT: cudaMemAdvise was REFUSED -- HET_PLACE placed nothing.\n");
}

/* The stress incantations.  They travel with every SIGHTING, of every class: a
   weak behaviour observed under a config nobody recorded is not reproducible, and
   an unreproducible result -- refutation OR confirmation -- is a much weaker one.

       "we report the number of times the weak behaviour was observed out of the
        total number of runs, together with the configuration of the stress ... so
        that our results can be reproduced."  -- Alglave et al., ASPLOS'15, 4.3. */
static void het_print_config(FILE *_ch, const het_obs_record *_r) {
  fprintf(_ch,
    "  config: stress_requested=0x%x spins=%llu/%llu do_stress_rounds=%llu "
    "enemies=%u enemy_rounds=%llu preload=%llu noise=%llu/%u (%u MB) place=%u\n",
    _r->stress_requested,
    (unsigned long long)_r->spin_rendezvous,
    (unsigned long long)(_r->spin_rendezvous + _r->spin_cap),
    (unsigned long long)_r->gpu_stress_rounds,
    _r->cpu_enemies,
    (unsigned long long)_r->cpu_enemy_rounds,
    (unsigned long long)_r->cpu_preload_ops,
    (unsigned long long)_r->noise_cpu_rounds, _r->noise_gpu_blocks,
    _r->noise_ws_mb, _r->place_mode);
}

/* The count to REPORT: the ground-truth scan's when it ran, else the windowed
   scan's -- which UNDER-counts (it can miss cycles, it cannot invent them). */
static uint64_t het_reported_count(const het_obs_record *_r) {
  return _r->exhaustive_valid ? _r->target_count_exhaustive
                              : _r->target_count_heuristic;
}

/* WHERE THE NUMBER CAME FROM.  A MEASUREMENT caveat, not a stress one -- which is why
   it is not in het_print_caveats() with the B4/B5 provenance lines.
   Every class needs it and only the Disallowed path used to print it: on a T_L>=2
   shape at production N the O(N^T_L) scan does not run, so BOTH a zero and a count
   come from the WINDOWED search over [c-W, c+W].  Saying "we could not expose it"
   without saying "in the window we actually searched" overstates the effort, and
   HET_WINDOW is an uncalibrated placeholder (B8 owns it). */
static void het_print_scan_caveat(FILE *_ch, const het_obs_record *_r, uint32_t cv) {
  if (!(cv & HET_CV_NO_EXHAUSTIVE)) return;
  fprintf(_ch,
    "  CAVEAT: the O(N^T_L) ground-truth scan did NOT run at N=%llu "
    "(HET_EXHAUSTIVE_MAX), so this count rests on the WINDOWED heuristic, whose "
    "radius HET_WINDOW is an uncalibrated placeholder (B8).  The window is a strict "
    "subset of the full range: it can MISS cycles, it cannot invent them -- so a "
    "sighting is real and a zero is NOT a measured zero.\n",
    (unsigned long long)_r->N);
}

/* "WE DID NOT SEE IT" -- phrased by ORACLE CLASS.
   There is no class-neutral way to say this, and picking one class's phrasing for
   all three is precisely the bug B6c exists to remove: "Disallowed outcome 0" is a
   FALSE STATEMENT about an oracle-Allowed test (its outcome is not disallowed) and
   about a NO-ORACLE one (nobody knows whether it is).  A COLD run of an Allowed test
   must not describe itself in the language of a forbidden one. */
static void het_print_notobserved(FILE *_ch, const het_obs_record *_r) {
  const char *what;
  switch (_r->het_oracle) {
  case ORACLE_DISALLOWED: what = "Disallowed outcome"; break;
  case ORACLE_ALLOWED:    what = "ALLOWED weak outcome"; break;
  default:                what = "outcome (NO ORACLE: neither allowed nor forbidden "
                                 "by the model)"; break;
  }
  fprintf(_ch,
    "  %s: %s NOT observed -- 0 / N=%llu frames (%llu examined); "
    "interleavings_detected=%llu.\n",
    _r->test_name, what, (unsigned long long)_r->N,
    (unsigned long long)_r->frames_examined,
    (unsigned long long)_r->interleavings_detected);
}

/* HOW HOT WAS THE HARNESS -- printed under every null of every class, because a
   non-observation is worth exactly what the co-running controls say it is worth
   (Q4 5.2: never print a bare "Never"). */
static void het_print_liveness(FILE *_ch, const het_obs_record *_r) {
  if (_r->control_compiled_in)
    fprintf(_ch,
      "  companion %s (minimal mutant) fired %llu time(s), P_rep=%.4f%%, on the "
      "same runs under the same stress config (tau_hot=%d).\n",
      _r->control_name ? _r->control_name : "(none)",
      (unsigned long long)_r->control_target_count,
      100.0 * _r->control_Prep, (int)HET_TAU_HOT);
  if (_r->canary_compiled_in)
    fprintf(_ch,
      "  canary %s fired %llu time(s) (tau_hot=%d) -- same launch, same stress, "
      "same C2C path.\n",
      _r->canary_name ? _r->canary_name : "(none)",
      (unsigned long long)_r->canary_target_count, (int)HET_TAU_HOT);
  if (!_r->control_compiled_in && !_r->canary_compiled_in) {
    /* Two tests are SUPPOSED to land here -- MP-{cg,gc}-sys-relaxed, which ARE the
       Layer-B canary and cannot co-run themselves.  Everything else landing here is
       an emitter bug, and the two cases must not print the same sentence. */
    if (_r->canary_name && _r->test_name
        && strcmp(_r->canary_name, _r->test_name) == 0)
      fprintf(_ch,
        "  THIS TEST IS THE LAYER-B CANARY (control-map.csv: `self'), so it cannot "
        "co-run itself and nothing else here can vouch for it.  Its own failure to "
        "fire is not a gap in the instrumentation -- it IS what \"the harness was "
        "cold\" MEANS: the most observable het shape we have did not fire.\n");
    else
      fprintf(_ch,
        "  *** NO CONTROL AND NO CANARY ARE CO-RUNNING IN THIS HARNESS *** -- both "
        "counts are structurally 0 and mean NOTHING.  This result is "
        "UNINTERPRETABLE.\n");
  }
}

static void het_verdict_print(FILE *_ch, const het_obs_record *_r) {
  uint32_t dq = 0, cv = 0;
  het_verdict_t v = het_verdict(_r, &dq, &cv);
  unsigned long long _n = (unsigned long long)_r->N;
  unsigned long long _hits = (unsigned long long)het_reported_count(_r);
  double _pct = _r->N ? (100.0 * (double)_hits / (double)_r->N) : 0.0;

  fprintf(_ch, "HetVerdict %s [%s] oracle=%s run=%d: %s\n",
          _r->test_name, het_conf_name(_r->reporting),
          het_oracle_name(_r->het_oracle), _r->run_id,
          het_verdict_name(v));

  /* ---- 0. The emitter did not tag this harness.  We do not know what the model
     predicts, so we do not know what we just measured.  Say ONLY that. */
  if (dq & HET_DQ_ORACLE_UNSET) {
    fprintf(_ch,
      "  *** THIS HARNESS CARRIES NO ORACLE CLASS (het_oracle == ORACLE_UNSET) ***\n"
      "  The emitter failed to tag it from tests/het/control-map.csv, so nothing can "
      "be concluded from this run in EITHER direction: the same observation refutes "
      "the model if the outcome is Disallowed and CONFIRMS it if the outcome is "
      "Allowed.  This is a BUILD BUG, not a result.  Rebuild; do not report.\n");
    return;
  }

  /* ================== THE SIGHTING (believed unconditionally) ==================
     Three classes, three meanings.  The refutation text below is reachable from
     HET_MISMATCH and from nowhere else, and HET_MISMATCH is reachable only from
     ORACLE_DISALLOWED -- which is the whole of B6c. */
  if (v == HET_MISMATCH) {
    fprintf(_ch,
      "  ** %s: the should-be-FORBIDDEN outcome was OBSERVED %llu time(s) "
      "(exhaustive) / %llu (heuristic) in N=%llu frames.\n"
      "  ** A single sighting REFUTES the model's prediction for this test.  "
      "This is a result, not a bug -- report it.\n",
      _r->test_name,
      (unsigned long long)_r->target_count_exhaustive,
      (unsigned long long)_r->target_count_heuristic, _n);
    if (cv & HET_CV_HEURISTIC_SIGHT)
      fprintf(_ch,
        "  NOTE: the sighting came from the WINDOWED heuristic (the O(N^T_L) "
        "ground-truth scan did not run at this N).  The window is a subset of "
        "the full range, so the recovered cycle is real -- but confirm it by "
        "re-running with -DHET_EXHAUSTIVE_MAX above N.\n");
    het_print_config(_ch, _r);
    het_print_caveats(_ch, _r, cv);
    return;
  }

  if (v == HET_ALLOWED_OBSERVED) {
    fprintf(_ch,
      "  %s: the ALLOWED weak outcome was OBSERVED %llu time(s) in N=%llu frames "
      "(%.4f%%).\n"
      "  This is the EXPECTED result.  The oracle PERMITS this outcome, so seeing it "
      "refutes NOTHING -- it is evidence the model is not OVER-STRONG (Iorga 4.4, the\n"
      "  from-below half of the verdict; the other half is the Disallowed tests' "
      "nulls).\n"
      "  No control is needed and none was used: a firing Allowed test IS ITS OWN "
      "CONTROL.\n",
      _r->test_name, _hits, _n, _pct);
    het_print_config(_ch, _r);
    het_print_scan_caveat(_ch, _r, cv);
    het_print_caveats(_ch, _r, cv);
    return;
  }

  if (v == HET_CHARACTERIZED) {
    /* Q4 R5.  Reached whether or not the outcome fired -- the characterization IS
       "outcome Y in Z% of frames, on a harness the canary shows was hot", and Z may
       be 0.  What it can never be reached from is a COLD harness (dq catches that
       first): characterizing a dead harness is a fabrication, not a finding. */
    fprintf(_ch,
      "  %s: NO ORACLE.  The compound model does not settle whether this outcome is "
      "allowed or forbidden\n"
      "  (IRIW/2+2W need multi-copy atomicity; WRC/ISA2/RWC need cross-device "
      "A-cumulativity -- the\n"
      "  ARM-MCA x PTX-non-MCA frontier Bagchi 4.2 explicitly defers).  So there is "
      "no prediction here\n"
      "  to confirm or refute, and this run is CHARACTERIZATION, NEVER VALIDATION.\n",
      _r->test_name);
    het_print_liveness(_ch, _r);
    fprintf(_ch,
      "  CHARACTERIZED: under that harness, this hardware exhibited the outcome %llu "
      "time(s) in N=%llu frames (%.4f%%); interleavings_detected=%llu.\n"
      "  Report it as \"what GH200 does where the CMCM is silent\".  It is NOT "
      "evidence for or against the model.\n",
      _hits, _n, _pct, (unsigned long long)_r->interleavings_detected);
    het_print_config(_ch, _r);
    het_print_scan_caveat(_ch, _r, cv);
    het_print_caveats(_ch, _r, cv);
    return;
  }

  /* ===================== NOT OBSERVED.  It NEVER prints alone. ================= */
  if (v == HET_ALLOWED_UNOBSERVED) {
    het_print_notobserved(_ch, _r);
    het_print_liveness(_ch, _r);
    fprintf(_ch,
      "  ALLOWED-UNOBSERVED -- an OBSERVABILITY result, NOT a model result.  The "
      "outcome is PERMITTED and\n"
      "  the harness was demonstrably hot, and we still could not expose it on this "
      "hardware under this\n"
      "  stress.  That says NOTHING about the CMCM in either direction; it says this "
      "shape's window is\n"
      "  narrow here.  It feeds the stress-tuning priority (B8).  The precedent for "
      "saying so plainly:\n"
      "    \"In fairness to the authors of [19], we were unable to observe weak "
      "behaviours using our\n"
      "     method on the Nvidia GTX 280 chip they used.\"\n"
      "                                     -- Alglave et al., ASPLOS'15, fn.7, p.577.\n");
    het_print_scan_caveat(_ch, _r, cv);
    het_print_caveats(_ch, _r, cv);
    return;
  }

  /* ---- What is left: the Disallowed null (the one the whole positive control
     exists for), and COLD-INVALID -- which is reachable from ALL THREE classes, so
     the line below MUST be phrased by class.  Printing "Disallowed outcome 0" on a
     cold ALLOWED test would be a false claim about the model in the very output that
     exists to stop us making one. */
  het_print_notobserved(_ch, _r);
  /* het_print_liveness covers all three sub-cases: a mutant co-running, a canary
     co-running, and NEITHER -- where it further distinguishes the two tests that ARE
     the canary (designed) from a harness whose control silently went missing (a bug
     that would otherwise let an uninterpretable null print as a result). */
  het_print_liveness(_ch, _r);

  if (v == HET_COLD_INVALID) {
    fprintf(_ch, "  DISCARD this null -- the harness was not demonstrably hot:\n");
    if (dq & HET_DQ_NO_CONTROL_BUILT)
      fprintf(_ch, "    - no positive control was compiled in (B6b)\n");
    if (dq & HET_DQ_NO_INTERLEAVING)
      fprintf(_ch, "    - interleavings_detected == 0: the two engines never "
                   "overlapped; nothing raced, so nothing could have been seen\n");
    if (dq & HET_DQ_CONTROLS_COLD)
      fprintf(_ch, "    - neither mu(T) nor the canary reached tau_hot=%d: a "
                   "known-ALLOWED weak behaviour on this very machinery did not "
                   "fire, so this harness is not shown to expose anything\n",
              (int)HET_TAU_HOT);
    if (dq & HET_DQ_STRESS_TRUNCATED)
      fprintf(_ch, "    - stress_truncated=%llu: stress STOPPED while tested "
                   "lanes were still running\n",
              (unsigned long long)_r->stress_truncated);
    if (dq & HET_DQ_SPIN_DEAD)
      fprintf(_ch, "    - the device-scope window-opener was requested "
                   "(HET_BARRIER_PCT) but recorded ZERO spins: it never ran\n");
    if (dq & HET_DQ_CPU_ENEMY_DEAD)
      fprintf(_ch, "    - the CPU enemies were requested but completed ZERO rounds\n");
    if (dq & HET_DQ_CPU_PRELOAD_DEAD)
      fprintf(_ch, "    - the M3 preload was requested but issued ZERO hints\n");
    if (dq & HET_DQ_NOISE_CPU_DEAD)
      fprintf(_ch, "    - the Grace half of the C2C noise did NOT run: this run "
                   "is not interconnect-stressed\n");
    if (dq & HET_DQ_NOISE_GPU_DEAD)
      fprintf(_ch, "    - the Hopper half of the C2C noise did NOT run: this run "
                   "is not interconnect-stressed\n");
    if (dq & HET_DQ_GPU_STRESS_DEAD)
      fprintf(_ch, "    - the GPU scratchpad stress was requested "
                   "(HET_PRE_STRESS_PCT/HET_MEM_STRESS_PCT) but het_do_stress "
                   "completed ZERO rounds: it never ran.  On NVIDIA silicon an "
                   "unstressed run observes nothing (Alglave 4.3.1)\n");
    het_print_caveats(_ch, _r, cv);
    return;
  }

  if (v == HET_CREDIBLE_NULL)
    fprintf(_ch,
      "  CREDIBLE NULL: the minimal mutant of THIS test fired reproducibly on "
      "the same run, so the harness demonstrably produced the cross-device "
      "interleaving this test's ordering is claimed to prevent.\n"
      "  Consistency evidence FOR the model -- NOT a proof.  Report as \"not "
      "observed under this effort\", never as \"forbidden\".\n");

  if (v == HET_WEAK_NULL) {
    fprintf(_ch, "  WEAK NULL -- reportable, but weaker than it looks:\n");
    if (cv & HET_CV_CANARY_ONLY)
      fprintf(_ch, "    - only the Layer-B canary fired: the C2C path is alive, "
                   "but this SHAPE's window was not demonstrably hit.  Escalate "
                   "stress tuning for it (B8).\n");
    if (cv & HET_CV_NO_EXHAUSTIVE)
      fprintf(_ch, "    - the O(N^T_L) ground-truth scan did not run at N=%llu "
                   "(HET_EXHAUSTIVE_MAX): the zero rests on the WINDOWED "
                   "heuristic, whose radius HET_WINDOW is an uncalibrated "
                   "placeholder (owned by B8).  It is not a measured zero.\n",
              (unsigned long long)_r->N);
  }

  het_print_caveats(_ch, _r, cv);
}

/* =========================================================================
 * THE STATISTICS LAYER (B7) -- what a "Never" is WORTH.
 *
 * B6 made a null INTERPRETABLE ("the harness was demonstrably hot, and we did
 * not see it").  It still carried no BOUND.  This layer attaches one, plus a
 * stopping rule and a stationarity gate, so the thesis can say
 *
 *     "not observed, under quantified effort, with the 95% bound on its
 *      run-level rate being p < X"
 *
 * instead of "not observed".  Everything here is a PURE FUNCTION of an array of
 * het_obs_records (Q3 6.6: the statistics are cheap -- host-side post-pass), so
 * it is unit-testable from synthetic record streams: hetlitmus/verify/statscheck.py.
 *
 * ---------------------------------------------------------------------------
 * R1, THE LOAD-BEARING CORRECTION: THE FRAME IS NOT THE TRIAL.
 *
 * The recovery scan validates FRAMES, and a run of N iterations contains N^{T_L}
 * of them (PerpLE VI-B.1), each frame a tuple of iterations that heavily overlaps
 * its neighbours.  So target_count is NOT n independent Bernoulli successes, and
 * Kirkham's 1 - e^{-n} fed with it returns ~1 VACUOUSLY.  The replication unit is
 * lifted to the (instance,run) CELL:
 *
 *     Y_{h,r} = 1[ target_count(h,r) >= 1 ]
 *
 * and THAT Y -- not the frame count -- is the n in every formula below.  The frame
 * count survives as effort/throughput evidence and nothing else.
 *
 * ---------------------------------------------------------------------------
 * THE REPLACEMENT ESTIMATOR: the rule of three does not survive burstiness.
 *
 * The rule of three (p < 3/N; Hanley & Lippman-Hand, JAMA 1983) is the n=0 dual of
 * Kirkham's model and inherits all of its assumptions.  Observations here arrive in
 * BURSTS -- a productive CPU/GPU alignment window emits many sightings, then a long
 * dry spell (Q1; PerpLE Fig.12 shows the thread skew is wide and drifting, not
 * fixed) -- and a bursty process parks MORE probability mass at zero, so a zero is
 * LESS informative than the iid rule claims.  The negative-binomial (Gamma-Poisson)
 * zero-event bound is the standard correction (Scholz 2008 unifies rule-of-three
 * across binomial/NB/Poisson):
 *
 *     P(X = 0) = (1 + mu/r)^{-r} = 0.05   =>   mu_upper(r) = r * (0.05^{-1/r} - 1)
 *
 *        r -> inf (Poisson) : 2.996   <- the textbook "3"
 *        r = 1  (geometric) : 19.0
 *        r = 0.5            : 199.5
 *
 * So the "3" inflates to ~19, or ~200.  Reporting a bare p < 3/N on a channel whose
 * measured Fano factor is ~20 is a ~6x OPTIMISTIC OVERCLAIM -- exactly the
 * port-an-assumption-without-checking-it error the project's standing rule exists to
 * prevent.  r_hat is therefore MEASURED, from the control channel, never assumed:
 * a bound that always returns the same number is the same bug as the constant-true
 * `_cond', the constant-false `_weak' and the inert stress layer.  If the dispersion
 * cannot be measured, NO BOUND IS PRINTED -- we do not fall back to 3/N.
 *
 * ---------------------------------------------------------------------------
 * THREE STRATA, THREE MEASUREMENTS (Q3 4.2, completed by B7b).
 *
 * Q3 3.2(b) writes the bound as mu_upper(r_hat)/R_eff, and 4.2 lists the separate
 * estimators feeding it.  B7 measured two of them; B7b adds the one B7 left as
 * "DIAGNOSTIC ONLY" -- and that omission was the binding constraint on the whole
 * campaign: each run was collapsed to ONE Bernoulli bit, so the denominator paid
 * the burstiness penalty (3 -> 19 via F_win) without ever collecting the
 * burstiness dividend (a correlated stream still carries more than one bit).
 * Each instrument answers its own question on its own stratum -- applying one
 * number to two corrections would double-count it:
 *
 *     F_win   Var/Mean of the PER-WINDOW control counts (marginal, within run)
 *             -> within-window burst MULTIPLICITY -> r_hat -> mu_upper(r_hat)
 *     tau_w   integrated autocorrelation time of the SAME stream's TEMPORAL
 *             axis (Geyer initial-positive-sequence, B7b)
 *             -> window-to-window correlation -> N_eff = HET_NWIN/tau_w
 *                clamped to [1, HET_NWIN]  (1 = B7's one-bit-per-run reading)
 *     F_cell  Var/Mean of the PER-CELL control totals  (across the R cells)
 *             -> the design effect DEFF = 1 + (m-1)rho
 *
 *     R_eff = R_usable * N_eff / max(1, F_cell)
 *
 * All corrections point the conservative way and every clamp is one-directional:
 * an under-dispersed F clamps to the Poisson floor, an unmeasured or at-cap tau
 * leaves N_eff = 1 (exactly B7), and N_eff can never exceed the resolution
 * HET_NWIN.  Disclosed interaction: F_cell, measured on run totals, absorbs part
 * of the same within-run correlation tau_w prices (E[F_cell] ~ tau_w*F_win under
 * run-independence), so the composition can pay for correlation twice -- wider,
 * never tighter; see the section-4b comment in het_stats_compute.
 *
 * ---------------------------------------------------------------------------
 * DIVERGENCE FROM KIRKHAM, DISCLOSED (we cite them, so we say where we differ).
 *
 * Kirkham 4.3 tests stationarity by FITTING A POISSON to the first 20% and last 10%
 * of a run and KS-testing the fit.  We run a TWO-SAMPLE KS between the early and
 * late window counts DIRECTLY, with no Poisson fit -- because the whole finding
 * above is that the Poisson is the wrong likelihood here, so testing a Poisson fit
 * would be testing the wrong null.  The check is otherwise theirs, including the
 * remedy: split at the change-point, and never report P_rep across it.
 *
 * Their precheck already fails 4 of 18 chip/test combinations in the GPU-only,
 * single-device case (Vega R p=7.6e-38; the Vega-LB rate jump at ~7M iterations),
 * which is why it is MANDATORY here and not optional: het adds occupancy warm-up,
 * thermal/DVFS over longer perpetual runs, and alignment/skew drift on top of
 * everything that was already breaking it.
 * ========================================================================= */

/* What the campaign SAW, at the (instance,run) unit. */
typedef enum {
  HET_OBS_VOID = 0,   /* not one usable cell: every run was COLD.  A bound computed
                         over these would be a bound on nothing. */
  HET_OBS_NEVER,      /* k = 0 usable cells observed it -> the false-negative bound */
  HET_OBS_SOMETIMES,
  HET_OBS_ALWAYS
} het_obs_class;

/* TRAP 3 -- CORROBORATION.  A false MISMATCH is a false REFUTATION of the compound
   model, the most damaging error the campaign can make, and Srivastava observed the
   mechanism that would forge one: a CONSTANT-READ artefact (a reader stuck on init or
   on a single value) yields a spurious 100%/0%.  But the fix is NOT to suppress
   sightings -- falsification is one-sided and a single genuine sighting refutes:

       "we emphasise that for correct GPU programming the possibility, not
        probability of weak behaviours is what matters."
                                        -- Alglave et al., ASPLOS'15, 4.3.

   These are two DIFFERENT questions -- "is the sighting REAL?" (decoder soundness)
   and "is it REPRODUCIBLE?" (statistical confidence) -- so they get two answers.
   het_verdict() still returns its immediate, loud, unconditional MISMATCH on the
   very first sighting; this tier is layered ON TOP and suppresses nothing. */
typedef enum {
  HET_MT_NONE = 0,
  HET_MT_UNCORROBORATED,  /* seen, but in <3 clean cells, or in a DEGENERATE one:
                             believe it, report it, and go reproduce it before it
                             is written up as a refutation of the CMCM. */
  HET_MT_CONFIRMED        /* >=3 distinct non-degenerate RUNS (R2: P_rep = 95%) */
} het_mismatch_tier;

/* Why a statistic is missing or weakened.  Each one is a thing that can silently
   turn this layer into a constant, so each one is PRINTED. */
#define HET_ST_FANO_UNMEASURED   (1u << 0) /* control never fired: NO BOUND, and we
                                              do NOT substitute the textbook 3/N   */
#define HET_ST_NONSTATIONARY     (1u << 1) /* KS rejected: P_rep SUPPRESSED (R4)   */
#define HET_ST_DEGEN_SIGHTING    (1u << 2) /* >=1 sighting failed the decode guard */
#define HET_ST_UNDERDISPERSED    (1u << 3) /* F < 1 measured: clamped to Poisson   */
#define HET_ST_BURSTY            (1u << 4) /* F >> 1: the bound WIDENED materially */
#define HET_ST_NO_DECODE_CHANNEL (1u << 5) /* no sync AND no observer: fail closed */
#define HET_ST_WIN_DESYNC        (1u << 6) /* sum(win[]) != total: the sub-tallies
                                              are DEAD or mis-indexed -- the whole
                                              dispersion estimate is void          */
#define HET_ST_KS_UNDERPOWERED   (1u << 7) /* too few windows to test stationarity */
#define HET_ST_CELLS_TRUNCATED   (1u << 8) /* more runs than HET_STATS_MAX_CELLS   */
#define HET_ST_CTRL_IS_CANARY    (1u << 9) /* dispersion calibrated off the Layer-B
                                              canary, not this test's own mu(T)    */
#define HET_ST_BOUND_VACUOUS    (1u << 10) /* p_bound >= 1: it bounds NOTHING      */
#define HET_ST_SELF_CONTROL     (1u << 11) /* co-runs no control: usable == fired  */
#define HET_ST_TAU_UNMEASURED   (1u << 12) /* no usable stream for the IPS: N_eff
                                              stays 1 -- each run counts as ONE
                                              trial, B7's maximally conservative
                                              reading (never a silent optimism)  */
#define HET_ST_TAU_AT_CAP       (1u << 13) /* tau_w clamped at HET_NWIN: the skew
                                              regime outlives the run at this
                                              resolution, so one run IS one
                                              alignment draw -- N_eff = 1 and
                                              B7's answer was right all along.
                                              Raise the swept HET_NWIN to probe
                                              whether finer windows resolve it. */
#define HET_ST_TAU_UNRESOLVED   (1u << 14) /* B7c: the pooled stream is shorter
                                              than HET_TAU_MIN_SAMPLES * tau_w, so
                                              tau is NOT RESOLVED and buys nothing:
                                              N_eff = 1 (B7's reading).  NOT a veto
                                              and NOT a failure -- an ACTIONABLE
                                              signal, "run more runs": the criterion
                                              is on the POOLED count R x HET_NWIN,
                                              so the guard RELAXES on its own as the
                                              campaign runs longer.  tau_runs_needed
                                              says how many usable runs it takes. */

typedef struct het_stats {
  const char *test_name;
  het_oracle_t oracle;
  het_obs_class obs;
  het_mismatch_tier tier;

  int R;              /* cells supplied  (= NUMBER_OF_RUN; H is 1 today)          */
  int R_usable;       /* cells whose het_verdict() is not COLD-INVALID            */
  int k;              /* cells with Y = 1[target_count >= 1]                      */
  int k_eff;          /* ... of those, the ones that pass the decode guard        */
  int k_runs;         /* distinct RUNS among them (the most independent draws)    */
  int n_degen;        /* sightings REJECTED by the guard (reported, never hidden) */

  int    win_samples;               /* (run,window) samples behind F_win          */
  double ctrl_mean, ctrl_var;       /* of the per-window control counts           */
  double F_win, F_cell;             /* the two strata                             */
  double r_hat;                     /* NB dispersion from F_win (inf = Poisson)   */
  double mu_upper;                  /* r(0.05^{-1/r} - 1)                         */
  double tau_w;                     /* integrated autocorrelation time, WINDOW
                                       units (Geyer IPS); -1 = NOT MEASURED       */
  double N_eff;                     /* effective independent samples PER RUN =
                                       HET_NWIN/tau_w, clamped to [1, HET_NWIN];
                                       1 when tau is unmeasured, or UNRESOLVED
                                       (B7c), which both = B7 exactly             */
  int    tau_runs_needed;           /* B7c: usable runs the aggregate needs for
                                       tau_w to clear HET_TAU_MIN_SAMPLES; 0 when
                                       tau was never measured.  THE PRICE OF THE
                                       CLAIM -- quoted whether or not it has been
                                       paid, so the invariant is exact:
                                       TAU_UNRESOLVED <=> R_usable < this          */
  double R_eff;                     /* R_usable * N_eff / max(1, F_cell)          */
  double p_bound;                   /* mu_upper / R_eff   (-1 = NOT COMPUTED)     */
  double P_rep;                     /* 1 - e^{-k_eff}     (-1 = NOT APPLICABLE)   */
  double acf1;                      /* lag-1 autocorrelation -- DIAGNOSTIC ONLY   */

  int    ks_pass, ks_n_early, ks_n_late, ks_split_window;
  double ks_D, ks_Dcrit;

  uint64_t N, frames_examined;      /* the effort disclosure                      */
  uint32_t flags;
} het_stats_t;

/* ---------------------------------------------------------------------------
 * THE ESTIMATORS.  Small, pure, and separately testable -- statscheck.py pins
 * het_mu_upper() against the closed form at r in {0.5, 1, 2, 5, 10, inf}. */

/* mu_upper(r) = r * (0.05^{-1/r} - 1), the 95% upper bound on the expected count
   of an NB(mu, r) process that was observed ZERO times.  Written with expm1 because
   the naive form cancels catastrophically as r grows -- and the r -> inf limit IS
   the textbook rule of three, so getting it wrong there would silently reproduce
   the very constant this function exists to replace.  0.05^{-1/r} = exp(ln(20)/r). */
static double het_mu_upper(double r) {
  const double L = -log(0.05);        /* ln 20 = 2.99573227... */
  if (!(r > 0.0))          return L;  /* no fit (incl. NaN)  -> the Poisson floor */
  if (!(r < HET_R_POISSON)) return L; /* r -> inf            -> the Poisson limit */
  return r * expm1(L / r);
}

/* Method of moments.  NB(mu, r) has Var = mu + mu^2/r, so Fano F = 1 + mu/r and
   r = mu/(F-1).  F <= 1 is Poisson-or-tighter: there is NO NB fit, and we return
   the Poisson limit rather than a small r -- letting an under-dispersed sample make
   the bound TIGHTER than 3 would be an overclaim in the one direction that matters. */
static double het_r_from_fano(double mean, double F) {
  if (!(F > 1.0) || !(mean > 0.0)) return HUGE_VAL;
  return mean / (F - 1.0);
}

/* Fano = Var/Mean of a sample.  Returns -1 when it CANNOT be measured (fewer than 2
   samples, or an all-zero stream): the caller must then print NO BOUND, not a
   default.  "A run where F_hat silently falls back to 1 is a run that reported the
   textbook rule of three while claiming to be dispersion-aware." */
static double het_fano(const double *x, int n, double *mean_out, double *var_out) {
  double s = 0.0, m, v = 0.0;
  int i;
  if (mean_out) *mean_out = 0.0;
  if (var_out)  *var_out  = 0.0;
  if (n < 2) return -1.0;
  for (i = 0; i < n; i++) s += x[i];
  m = s / (double)n;
  for (i = 0; i < n; i++) { double d = x[i] - m; v += d * d; }
  v /= (double)(n - 1);                       /* sample variance */
  if (mean_out) *mean_out = m;
  if (var_out)  *var_out  = v;
  if (!(m > 0.0)) return -1.0;                /* an all-zero stream measures nothing */
  return v / m;
}

/* ---------------------------------------------------------------------------
 * B7b -- THE INFORMATION B7 THREW AWAY: the integrated autocorrelation time.
 *
 * B7 collapses each run to ONE Bernoulli bit (Y = 1[count >= 1]): 100,000
 * iterations become one trial.  That is the tau = run-length WORST CASE, and it
 * pays the burstiness penalty (F_win widens mu_upper, 3 -> 19) without ever
 * collecting the burstiness dividend (a correlated stream still carries MORE
 * than one trial of information).  The standard treatment of a correlated
 * sequence is to DISCOUNT it, not discard it:
 *
 *     N_eff = N / tau ,   tau = integrated autocorrelation time
 *                             = 1 + 2 * sum_k rho_k
 *
 * -- the same design-effect logic Q3 2.3 already applies ACROSS cells (DEFF,
 * F_cell), applied WITHIN the run (Q3 4.2: "autocorrelation / N_eff within a
 * run"; open question 2).  tau is estimated from the control's per-window
 * stream with GEYER'S INITIAL-POSITIVE-SEQUENCE estimator (Geyer, "Practical
 * Markov Chain Monte Carlo", Statistical Science 7(4), 1992, 3.3: sum the
 * adjacent-pair sums Gamma_m = rho_{2m} + rho_{2m+1} while they stay positive):
 * the standard IACT estimator in MCMC practice, robust on short series, and --
 * unlike 1/(1-acf1), which a slowly-decaying ACF makes arbitrarily optimistic
 * -- it reads the WHOLE initial decay.  On an AR(1) stream it recovers the
 * closed form tau = (1+rho)/(1-rho) exactly in expectation, which is what
 * statscheck.py pins it against (rho in {0, 0.5, 0.9, 0.99}).
 *
 * Estimator mechanics, disclosed:
 *   - lags are computed WITHIN runs only and pooled across them (a lag across a
 *     run boundary is not a lag: runs are re-seeded), deviations taken from the
 *     GLOBAL mean -- so an across-run rate difference inflates tau, which errs
 *     toward N_eff = 1, the conservative direction;
 *   - autocovariances use the biased 1/n normalisation (standard for IACT:
 *     damps the noisy high lags);
 *   - the result is CLAMPED to [1, wlen].  The floor: tau < 1 is estimation
 *     noise (an anti-correlated stream cannot yield more independent samples
 *     than it has windows).  The ceiling: a correlation the stream cannot
 *     resolve must saturate at "one run = one draw", never extrapolate.  Both
 *     clamps are one-directional honesty, same as het_r_from_fano's.
 *
 * Returns -1 when tau CANNOT be measured (a stream shorter than one whole run,
 * fewer than 2 windows/run, or zero variance) -- the caller then keeps
 * N_eff = 1, which IS B7's reading.  A correct implementation contains B7 as
 * its conservative special case. */
static double het_tau_ips(const double *win, int nwin, int wlen, double mean) {
  double g0 = 0.0, s = 0.0, tau;
  int nrun, r, w, k, m, exhausted = 1;
  if (wlen < 2 || nwin < wlen) return -1.0;
  nrun = nwin / wlen;                    /* whole runs only (callers pass whole runs) */
  for (r = 0; r < nrun; r++)
    for (w = 0; w < wlen; w++) {
      double d = win[r * wlen + w] - mean;
      g0 += d * d;
    }
  g0 /= (double)(nrun * wlen);
  if (!(g0 > 0.0)) return -1.0;          /* a flat stream has no time structure */
  for (m = 0; 2 * m < wlen; m++) {
    double G = 0.0;
    for (k = 2 * m; k <= 2 * m + 1 && k < wlen; k++) {
      double g = 0.0;
      if (k == 0) { G += 1.0; continue; }             /* rho_0 = 1 */
      for (r = 0; r < nrun; r++)
        for (w = 0; w + k < wlen; w++)
          g += (win[r * wlen + w] - mean) * (win[r * wlen + w + k] - mean);
      G += (g / (double)(nrun * wlen)) / g0;          /* biased 1/n, then rho_k */
    }
    if (!(G > 0.0)) { exhausted = 0; break; }  /* Geyer: first non-positive pair */
    s += G;
  }
  /* Ran out of lags with every pair still positive: the stream NEVER
     decorrelated in view, so the honest answer is the ceiling ("one run is one
     regime"), not the truncated partial sum -- which would under-read tau and
     over-credit N_eff, the one direction the clamps exist to forbid. */
  if (exhausted) return (double)wlen;
  tau = 2.0 * s - 1.0;
  if (tau < 1.0) tau = 1.0;
  if (tau > (double)wlen) tau = (double)wlen;
  return tau;
}

/* B7c -- THE COST OF THE CLAIM.  The reliability criterion is on the POOLED sample
   count (nwin = usable runs x HET_NWIN), so an unresolved tau is not a dead end: it
   is a PRICE, and this is the price.  Returns the number of USABLE runs the
   aggregate would have to hold for tau_w to clear HET_TAU_MIN_SAMPLES * tau_w
   samples -- i.e. what "run more runs" actually costs, in runs.

   This is why the guard is a signal and not a veto: at HET_NWIN = 128, R = 10 pools
   1,280 samples and resolves tau <= 25.6; R = 100 pools 12,800 and resolves tau <=
   256.  Grow R, not N (Q3 F4) -- a bigger N adds correlated frames inside the same
   alignment windows, while a fresh run adds a fresh phase/seed/thermal draw.
   (Raising the swept HET_NWIN also raises the pooled count, but it trades against
   resolution: finer windows correlate with each other and push tau_w back up.  R is
   the clean lever.)  0 = nothing to buy: tau resolved, or never measured. */
static int het_tau_runs_needed(double tau_w) {
  double need;
  if (!(tau_w > 0.0)) return 0;                     /* unmeasured: no price to quote */
  need = HET_TAU_MIN_SAMPLES * tau_w / (double)HET_NWIN;
  return (int)need + (((double)(int)need < need) ? 1 : 0);   /* ceil */
}

/* R3 -- HOW LONG TO RUN BEFORE A "NEVER" MEANS ANYTHING.  Kirkham's necessary-iteration
   inverse N = log(1-P_rep)/log(1-p) (1.1 p.226:4), fed with RUN-LEVEL rates and inflated
   by the measured dispersion:

       R  >=  F_hat * log(0.05) / log(1 - p_min)

   i.e. run enough near-independent CELLS that, had the target's rate equalled p_min --
   the hardest behaviour we can actually see -- we would have had a 95% chance to catch
   it.  Grow R, NOT N (Q3 F4): beyond the point where a run has explored its skew range,
   extra N adds CORRELATED frames inside the same alignment windows, while extra R adds
   genuinely fresh phase/seed/thermal draws.

   Returns -1 when p_min is UNSET.  It is unset today and that is not a stub: the het
   p_min does not exist in the literature (see HET_P_MIN), so any number here would be
   imported from a different experiment.  A budget invented from the wrong experiment is
   worse than no budget, because it looks like one. */
static double het_budget_runs(double p_min, double F) {
  if (!(p_min > 0.0) || !(p_min < 1.0)) return -1.0;   /* UNSET -> NOT SIZED */
  if (!(F > 1.0)) F = 1.0;
  return F * log(0.05) / log(1.0 - p_min);
}

static int het_dcmp(const void *a, const void *b) {
  double x = *(const double *)a, y = *(const double *)b;
  return (x < y) ? -1 : ((x > y) ? 1 : 0);
}

/* Two-sample KS.  Returns 1 = stationary (failed to reject), 0 = REJECTED,
   -1 = underpowered.  Sorts in place.  On discrete counts the test is conservative
   (ties depress D), i.e. it UNDER-rejects -- so a KS_pass here is the weaker claim
   and a KS_split is the strong one.  Stated because it matters which way the
   conservatism cuts. */
static int het_ks2(double *a, int na, double *b, int nb,
                   double *D_out, double *Dcrit_out) {
  int i = 0, j = 0;
  double D = 0.0;
  *D_out = 0.0; *Dcrit_out = 0.0;
  if (na < 2 || nb < 2) return -1;
  qsort(a, (size_t)na, sizeof(double), het_dcmp);
  qsort(b, (size_t)nb, sizeof(double), het_dcmp);
  while (i < na && j < nb) {
    double x = (a[i] < b[j]) ? a[i] : b[j];
    double d;
    while (i < na && a[i] <= x) i++;
    while (j < nb && b[j] <= x) j++;
    d = fabs((double)i / (double)na - (double)j / (double)nb);
    if (d > D) D = d;
  }
  *D_out = D;
  *Dcrit_out = HET_KS_C05 * sqrt(((double)na + (double)nb)
                                 / ((double)na * (double)nb));
  return (D <= *Dcrit_out) ? 1 : 0;
}

/* Kirkham's remedy for a non-stationary run is to SPLIT IT AT THE CHANGE-POINT
   ("non-stable runs can then be restarted from the point of instability", 5.1).
   This locates it: the window index whose before/after means differ most. */
static int het_changepoint(const double *prof, int n) {
  int i, best = -1;
  double bd = -1.0;
  for (i = 1; i < n; i++) {
    double s1 = 0.0, s2 = 0.0, d;
    int j;
    for (j = 0; j < i; j++) s1 += prof[j];
    for (j = i; j < n; j++) s2 += prof[j];
    d = fabs(s1 / (double)i - s2 / (double)(n - i));
    if (d > bd) { bd = d; best = i; }
  }
  return best;
}

/* THE DECODE GUARD (TRAP 3).  Is this cell's decode trustworthy, or could the
   "sighting" be Srivastava's constant-read artefact?

   THE FIELD BEING ZERO IS NOT THE SAME AS THE DECODE BEING DEGENERATE.  Measured on
   the emitted corpus: 316 of the 338 populate the synchrony fields, and the other
   22 -- every 2+2W, the store-only shape, which has no reader and therefore cannot
   HAVE a constant-read artefact -- leave them at their memset zero and decode
   through the OBSERVER instead.  Every one of the 338 has exactly one of the two
   channels or both (266 sync / 22 observer / 50 both / 0 neither), so the guard
   switches channel rather than firing blind.  Reading `skew_stddev == 0' as
   "degenerate" would have condemned all 22 forever.

   The `no channel at all' arm is unreachable in the shipped corpus and FAILS CLOSED
   anyway: reaching it means the emitter compiled a harness with no way to decode
   what it saw, and a sighting nothing can vouch for must not be counted toward a
   refutation of the model. */
static int het_cell_degenerate(const het_obs_record *r) {
  if (r->sync_valid)
    return (r->distinct_decoded_iters < (uint64_t)HET_THETA_DISTINCT)
        || (r->skew_stddev == 0.0);
  if (r->obs_valid)
    return (r->observer_unique_count < (uint64_t)HET_THETA_DISTINCT);
  return 1;
}

static const uint32_t *het_ctrl_win(const het_obs_record *r, int use_canary) {
  return use_canary ? r->canary_win : r->control_win;
}
static uint64_t het_ctrl_total(const het_obs_record *r, int use_canary) {
  return use_canary ? r->canary_target_count : r->control_target_count;
}

/* ---------------------------------------------------------------------------
 * THE AGGREGATE.  A pure function of the record stream (Q3 6.6). */
static void het_stats_compute(const het_obs_record *recs, int n, het_stats_t *st) {
  double cell[HET_STATS_MAX_CELLS];
  double win[HET_STATS_MAX_CELLS * HET_NWIN];
  double early[HET_STATS_MAX_CELLS * HET_NWIN];
  double late[HET_STATS_MAX_CELLS * HET_NWIN];
  double prof[HET_NWIN];
  int    runs[HET_STATS_MAX_CELLS];
  int i, w, nwin = 0, ne = 0, nl = 0, ncell = 0, nruns = 0, use_canary;
  int n_early, n_late, ks;
  uint64_t mu_total = 0, can_total = 0;
  int mu_present = 0;

  memset(st, 0, sizeof *st);
  st->p_bound = -1.0;                 /* -1 = NOT COMPUTED.  Never a silent 3/N. */
  st->P_rep   = -1.0;                 /* -1 = NOT APPLICABLE                     */
  st->F_win   = -1.0;
  st->F_cell  = -1.0;
  st->r_hat   = HUGE_VAL;
  st->tau_w   = -1.0;                 /* -1 = NOT MEASURED                       */
  st->N_eff   = 1.0;                  /* one trial per run: B7's reading, until
                                         a MEASURED tau says otherwise.  The
                                         default is the conservative case, so an
                                         unmeasured stream can never buy a
                                         tighter bound than B7 reported.        */
  st->ks_split_window = -1;
  if (n <= 0) { st->obs = HET_OBS_VOID; st->flags |= HET_ST_FANO_UNMEASURED; return; }
  st->test_name = recs[0].test_name;
  st->oracle    = recs[0].het_oracle;
  st->N         = recs[0].N;
  st->R         = n;
  if (n > HET_STATS_MAX_CELLS) { n = HET_STATS_MAX_CELLS;
                                 st->flags |= HET_ST_CELLS_TRUNCATED; }

  /* ---- 1. WHICH control channel calibrates the dispersion.
     mu(T) is the shape-matched proxy (same shape, same scope, ONE ordering
     primitive weaker) so it is preferred where it exists and fired; the canary is
     the universal het-MP floor and is all the other 322 have.  A bound calibrated
     off a different shape's burstiness is a weaker claim, so which one was used is
     RECORDED and PRINTED rather than left for the reader to guess. */
  for (i = 0; i < n; i++) {
    if (recs[i].control_compiled_in) mu_present = 1;
    mu_total  += recs[i].control_target_count;
    can_total += recs[i].canary_target_count;
  }
  use_canary = (mu_present && mu_total > 0) ? 0 : 1;
  if (use_canary) st->flags |= HET_ST_CTRL_IS_CANARY;
  (void)can_total;

  /* ---- 2. The cells.  het_verdict() is already a pure function of the record, so
     the aggregate REUSES it rather than re-deriving liveness (and thereby inherits
     every B4/B5 disqualifier and all of B6c's oracle-awareness for free). */
  for (i = 0; i < n; i++) {
    uint32_t dq = 0, cv = 0;
    het_verdict_t v = het_verdict(&recs[i], &dq, &cv);
    int y   = (het_reported_count(&recs[i]) >= 1);
    int deg = het_cell_degenerate(&recs[i]);
    uint64_t tot = het_ctrl_total(&recs[i], use_canary);
    uint64_t sum = 0;

    /* A SIGHTING is never COLD (het_verdict believes a positive unconditionally),
       so a usable-cell count can never discard one. */
    if (v != HET_COLD_INVALID) st->R_usable++;

    if (!recs[i].sync_valid && !recs[i].obs_valid)
      st->flags |= HET_ST_NO_DECODE_CHANNEL;

    if (y) {
      st->k++;
      if (deg) { st->n_degen++; st->flags |= HET_ST_DEGEN_SIGHTING; }
      else {
        int j, seen = 0;
        st->k_eff++;
        for (j = 0; j < nruns; j++) if (runs[j] == recs[i].run_id) seen = 1;
        if (!seen) runs[nruns++] = recs[i].run_id;
      }
    }

    /* THE SELF-PROVING INVARIANT.  The window bump sits on the same line, under the
       same predicate, as the total -- so these must agree.  If they do not, the
       sub-tallies are dead or mis-indexed and EVERY dispersion number below is
       fiction.  This is the one check that can catch a dead-code-eliminated tally on
       real hardware, where the tally is supposed to be nonzero. */
    for (w = 0; w < HET_NWIN; w++) sum += het_ctrl_win(&recs[i], use_canary)[w];
    if (sum != tot) st->flags |= HET_ST_WIN_DESYNC;

    st->frames_examined += recs[i].frames_examined;

    /* Only a USABLE cell's control stream may calibrate anything: the dispersion of
       a dead harness is the dispersion of nothing. */
    if (v == HET_COLD_INVALID) continue;
    cell[ncell++] = (double)tot;
    for (w = 0; w < HET_NWIN; w++)
      win[nwin++] = (double)het_ctrl_win(&recs[i], use_canary)[w];
  }
  st->k_runs = nruns;

  /* ---- 3. The observation class at the (instance,run) unit (R1).

     THE SELF-CANARY SELECTION EFFECT.  A cell is usable if it FIRED or if its control
     was hot -- and MP-{cg,gc}-sys-relaxed co-run NO control (they ARE the Layer-B
     canary and a test cannot control itself, B6b).  For those two rows "usable" is
     therefore DEFINED BY firing: every run in which they did not fire is COLD and is
     discarded, so the survivors are, tautologically, exactly the ones that fired.
     Classifying over usable cells would then report ALWAYS for a canary that fired in
     3 runs out of 10 -- and that rate is the number the whole campaign is calibrated
     against.  So for these rows the denominator is R, the runs actually executed. */
  { int denom;
    for (i = 0; i < n; i++)
      if (recs[i].control_compiled_in || recs[i].canary_compiled_in) break;
    if (i == n) st->flags |= HET_ST_SELF_CONTROL;
    denom = (st->flags & HET_ST_SELF_CONTROL) ? st->R : st->R_usable;
    if (st->R_usable == 0)    st->obs = HET_OBS_VOID;
    else if (st->k == 0)      st->obs = HET_OBS_NEVER;
    else if (st->k >= denom)  st->obs = HET_OBS_ALWAYS;
    else                      st->obs = HET_OBS_SOMETIMES;
  }

  /* ---- 4. Dispersion, on the two strata. */
  st->win_samples = nwin;
  st->F_win  = het_fano(win, nwin, &st->ctrl_mean, &st->ctrl_var);
  st->F_cell = het_fano(cell, ncell, NULL, NULL);
  if (st->F_win < 0.0 || (st->flags & HET_ST_WIN_DESYNC)) {
    st->flags |= HET_ST_FANO_UNMEASURED;
  } else {
    if (st->F_win <  1.0)          st->flags |= HET_ST_UNDERDISPERSED;
    if (st->F_win >= HET_BURSTY_F) st->flags |= HET_ST_BURSTY;
    st->r_hat = het_r_from_fano(st->ctrl_mean, st->F_win);
  }

  /* ---- 4b. B7b -- THE THIRD INSTRUMENT, on the third stratum: the TEMPORAL
     axis of the same per-window stream.  F_win prices the within-window burst
     MULTIPLICITY (it widens the numerator, mu_upper); tau_w prices the
     window-to-window CORRELATION (it discounts the denominator's sample count);
     F_cell prices the across-cell spread.  Three different questions, three
     measurements -- applying any one of them to another's correction would
     double-count it (the F_win/F_cell separation rule, extended).
     One interaction IS disclosed rather than removed: F_cell is measured on
     run TOTALS, and under across-run independence a within-run correlation
     also inflates run-total variance (E[F_cell] ~ tau_w * F_win for a
     stationary stream), so composing N_eff with F_cell can price part of the
     correlation twice.  Both corrections point the same way -- WIDER -- so the
     composition is conservative, never optimistic; B8 may sharpen it once
     GH200 numbers exist.  Measured only where the dispersion itself was (a
     desynced or dead stream measures nothing). */
  if (st->flags & HET_ST_FANO_UNMEASURED) {
    st->flags |= HET_ST_TAU_UNMEASURED;
  } else {
    st->tau_w = het_tau_ips(win, nwin, HET_NWIN, st->ctrl_mean);
    st->tau_runs_needed = het_tau_runs_needed(st->tau_w);
    if (st->tau_w > 0.0) {
      /* ---- B7c: IS tau ITSELF RESOLVED?  B7b clamped tau in the one direction it
         could see (exhaustion -> cap, raw < 1 -> 1) and then TRUSTED the number in
         between.  But the ESTIMATOR is not one-directional: Geyer IPS truncates at
         the first non-positive pair, and on a stream too short for its own tau a
         spurious non-positive pair arrives early, the sum is cut off, and tau comes
         back far BELOW both the truth and the HET_NWIN ceiling -- so TAU_AT_CAP
         never fires, nothing is flagged, and the under-read tau OVER-credits N_eff
         and makes the false-negative bound TIGHTER THAN THE TRUTH.  That is an
         overclaim, and it bites hardest in exactly the regime we most expect (slow
         skew drift, "one run is one alignment regime") -- precisely where B7's
         conservative reading was RIGHT.
         The fix is the reliability threshold, NOT a bias correction: a series must
         be ~HET_TAU_MIN_SAMPLES times longer than the tau it claims to measure
         (see HET_TAU_MIN_SAMPLES for the grounding, and for why the THRESHOLD
         transfers between estimators but the DIRECTION does not).
         nwin is the POOLED count across usable runs, so the guard SELF-RELAXES as
         the campaign grows -- it is a price, not a veto (het_tau_runs_needed). */
      if ((double)nwin < HET_TAU_MIN_SAMPLES * st->tau_w) {
        st->flags |= HET_ST_TAU_UNRESOLVED;
        st->N_eff  = 1.0;                    /* the B7 reading, kept intact */
      } else {
        if (st->tau_w >= (double)HET_NWIN) st->flags |= HET_ST_TAU_AT_CAP;
        st->N_eff = (double)HET_NWIN / st->tau_w;
        /* The clamp is the honesty: a stream of HET_NWIN windows cannot witness
           more than HET_NWIN independent samples, nor fewer than 1. */
        if (st->N_eff < 1.0)               st->N_eff = 1.0;
        if (st->N_eff > (double)HET_NWIN)  st->N_eff = (double)HET_NWIN;
      }
    } else {
      st->flags |= HET_ST_TAU_UNMEASURED;   /* N_eff stays 1: the B7 reading */
    }
  }

  /* lag-1 autocorrelation, WITHIN runs (never across a run boundary -- the runs are
     re-seeded, so a lag across one is not a lag).  DIAGNOSTIC ONLY, still: what
     enters the bound is tau_w (section 4b), the INTEGRATED autocorrelation time --
     acf1 alone is not enough, because a slowly-decaying ACF has a tau far larger
     than 1/(1-acf1) suggests.  acf1 survives as the one-number burstiness
     explainer and as a cross-check on tau_w's direction. */
  if (nwin >= 2 && st->ctrl_var > 0.0) {
    double num = 0.0, den = 0.0;
    for (i = 0; i + HET_NWIN <= nwin; i += HET_NWIN)
      for (w = 0; w < HET_NWIN; w++) {
        double d = win[i + w] - st->ctrl_mean;
        den += d * d;
        if (w + 1 < HET_NWIN) num += d * (win[i + w + 1] - st->ctrl_mean);
      }
    st->acf1 = (den > 0.0) ? num / den : 0.0;
  }

  /* ---- 5. THE STATIONARITY GATE (R4-i; MANDATORY, not optional).
     Kirkham's first-20%-vs-last-10% split, transplanted to the window axis: early
     windows from every usable run against late windows from every usable run.  That
     is the axis on which warm-up, thermal/DVFS drift and alignment drift all act. */
  n_early = (HET_NWIN * 20) / 100; if (n_early < 1) n_early = 1;
  n_late  = (HET_NWIN * 10) / 100; if (n_late  < 1) n_late  = 1;
  for (i = 0; i + HET_NWIN <= nwin; i += HET_NWIN) {
    for (w = 0; w < n_early; w++)          early[ne++] = win[i + w];
    for (w = HET_NWIN - n_late; w < HET_NWIN; w++) late[nl++] = win[i + w];
  }
  st->ks_n_early = ne; st->ks_n_late = nl;
  /* A KS ON AN ALL-ZERO STREAM PASSES FOR FREE, and a gate that passes for free is
     the signature bug of this project.  The two `self' canary rows
     (MP-{cg,gc}-sys-relaxed) co-run NO control by construction -- a test cannot be
     its own control -- so their control stream is structurally empty; so is that of
     any harness whose control never fired.  D would then be 0 against 0, the gate
     would report `pass', and P_rep would be unlocked by a test that never ran.
     Stationarity that CANNOT be tested must not be reported as tested. */
  ks = (st->flags & HET_ST_FANO_UNMEASURED)
       ? -1
       : het_ks2(early, ne, late, nl, &st->ks_D, &st->ks_Dcrit);
  if (ks < 0) {
    /* Cannot test => cannot claim.  FAIL CLOSED: ks_pass stays 0, so P_rep is
       suppressed below exactly as it would be on a rejection.  A stationarity gate
       that passes when it could not run is not a gate. */
    st->ks_pass = 0;
    st->flags |= HET_ST_KS_UNDERPOWERED;
  } else {
    st->ks_pass = ks;
    if (!ks) {
      st->flags |= HET_ST_NONSTATIONARY;
      for (w = 0; w < HET_NWIN; w++) {
        double s = 0.0; int c = 0;
        for (i = 0; i + HET_NWIN <= nwin; i += HET_NWIN) { s += win[i + w]; c++; }
        prof[w] = c ? s / (double)c : 0.0;
      }
      st->ks_split_window = het_changepoint(prof, HET_NWIN);
    }
  }

  /* ---- 6. R2 -- OBSERVED: P_rep at the (instance,run) unit, from k_eff, NOT from
     the frame count.  Suppressed across a non-stationary boundary (R4).

     k_eff > 0 IS LOAD-BEARING, not a guard against division by zero.  With k_eff = 0
     -- every sighting rejected by the decode guard -- the formula returns
     1 - e^0 = 0, and "P_rep = 0.00%" reads as "this behaviour NEVER reproduces" when
     what actually happened is that we have NO CLEAN CELL TO ESTIMATE FROM.  That is a
     constant 0 wearing a statistic's clothes, and it is the same silent falsification
     as the constant-false `_weak': a number that looks like evidence and is the
     absence of it.  There is no estimate here, so none is reported. */
  if (st->obs == HET_OBS_SOMETIMES || st->obs == HET_OBS_ALWAYS)
    if (st->ks_pass && st->k_eff > 0)
      st->P_rep = 1.0 - exp(-(double)st->k_eff);

  /* ---- 7. R3 -- UNOBSERVED: the dispersion-aware false-negative bound.
     NOT COMPUTED (and emphatically NOT replaced by 3/N) when the dispersion could
     not be measured.

     B7b: the denominator collects the dividend the numerator already paid for.
     R_eff = R_usable * N_eff / DEFF -- each usable run contributes its MEASURED
     effective sample count instead of the worst-case 1.  The unit of p_bound
     therefore refines from "per run" to "per effective sample" (one
     tau_w-window alignment epoch); the implied RUN-level bound is
     N_eff * p_bound = mu_upper * DEFF / R_usable, i.e. EXACTLY B7's number --
     the discount never weakens the run-level claim, it adds resolution beneath
     it, and at N_eff = 1 (tau unmeasured or at cap) it IS B7. */
  if (st->obs == HET_OBS_NEVER && !(st->flags & HET_ST_FANO_UNMEASURED)) {
    double deff = (st->F_cell > 1.0) ? st->F_cell : 1.0;
    st->R_eff    = (double)st->R_usable * st->N_eff / deff;
    st->mu_upper = het_mu_upper(st->r_hat);
    if (st->R_eff > 0.0) st->p_bound = st->mu_upper / st->R_eff;
    /* A BOUND ABOVE 1 IS NOT A BOUND.  p_run is a PROBABILITY, so "p < 6e10" is not a
       weak claim, it is the ABSENCE of a claim -- and printing it as a number invites
       it into a table as though it meant something.  This is what a heavily bursty
       channel does to a null: the process parks so much mass at zero that seeing zero
       tells you almost nothing (that IS the finding, and it is the honest one).  The
       remedy is Q3's F4: grow R -- more independent cells -- NOT bigger N, which only
       adds correlated frames to the same few alignment windows. */
    if (st->p_bound >= 1.0) st->flags |= HET_ST_BOUND_VACUOUS;
  }

  /* ---- 8. TRAP 3 -- the corroboration tier.  Layered ON TOP of het_verdict()'s
     immediate MISMATCH; it never suppresses one.  Distinct RUNS, not merely distinct
     cells: runs are re-seeded and carry a fresh phase/thermal draw, so they are the
     most independent replicates the harness produces (Q3 3.1, F4). */
  if (st->oracle == ORACLE_DISALLOWED && st->k > 0)
    st->tier = (st->k_runs >= 3) ? HET_MT_CONFIRMED : HET_MT_UNCORROBORATED;
}

static const char *het_obs_class_name(het_obs_class c) {
  switch (c) {
  case HET_OBS_NEVER:     return "Never";
  case HET_OBS_SOMETIMES: return "Sometimes";
  case HET_OBS_ALWAYS:    return "Always";
  default:                return "VOID";
  }
}

static const char *het_tier_name(het_mismatch_tier t) {
  switch (t) {
  case HET_MT_CONFIRMED:      return "MISMATCH-CONFIRMED";
  case HET_MT_UNCORROBORATED: return "MISMATCH-UNCORROBORATED";
  default:                    return "none";
  }
}

/* The machine-readable line.  hetlitmus/oracle-compare.sh parses THIS and layers the
   annotation onto its MATCH/MISMATCH/NO-ORACLE table (Q3 R6: augment, do not
   replace).  oracle= is first-class: Y = 1[count >= 1] means the OPPOSITE thing for
   an Allowed test and a Disallowed one, so a row that does not carry its oracle class
   cannot be pooled with anything. */
static void het_stats_line(FILE *_ch, const het_stats_t *_s) {
  fprintf(_ch,
    "HetStats %s oracle=%s obs=%s R=%d usable=%d k=%d k_eff=%d k_runs=%d degen=%d "
    "ctrl=%s win_n=%d nwin=%d F_win=%.4f F_cell=%.4f r_hat=%.4f mu_upper=%.4f "
    "tau_w=%.4f N_eff=%.4f tau_need=%d R_eff=%.4f "
    "p_bound=%.6g P_rep=%.6g acf1=%.4f ks=%s ks_D=%.4f ks_Dcrit=%.4f ks_split=%d "
    "tier=%s N=%llu frames=%llu flags=0x%x\n",
    _s->test_name ? _s->test_name : "(none)", het_oracle_name(_s->oracle),
    het_obs_class_name(_s->obs), _s->R, _s->R_usable, _s->k, _s->k_eff, _s->k_runs,
    _s->n_degen,
    (_s->flags & HET_ST_CTRL_IS_CANARY) ? "canary" : "mu(T)",
    _s->win_samples, (int)HET_NWIN, _s->F_win, _s->F_cell,
    (_s->r_hat >= HET_R_POISSON) ? INFINITY : _s->r_hat,
    _s->mu_upper, _s->tau_w, _s->N_eff, _s->tau_runs_needed,
    _s->R_eff, _s->p_bound, _s->P_rep, _s->acf1,
    (_s->flags & HET_ST_KS_UNDERPOWERED) ? "underpowered"
      : (_s->ks_pass ? "pass" : "SPLIT"),
    _s->ks_D, _s->ks_Dcrit, _s->ks_split_window,
    het_tier_name(_s->tier),
    (unsigned long long)_s->N, (unsigned long long)_s->frames_examined,
    _s->flags);
}

/* The human block.  Same contract as het_verdict_print: the interpretation travels
   with the number, so a reader cannot pick the number up without it. */
static void het_stats_print(FILE *_ch, const het_stats_t *_s) {
  het_stats_line(_ch, _s);

  fprintf(_ch, "HetStats %s: %d cell(s) [(instance,run)], %d usable, observed in %d "
               "(%d after the decode guard, across %d distinct run(s)).\n",
          _s->test_name ? _s->test_name : "(none)",
          _s->R, _s->R_usable, _s->k, _s->k_eff, _s->k_runs);

  if (_s->flags & HET_ST_CELLS_TRUNCATED)
    fprintf(_ch, "  *** MORE RUNS THAN HET_STATS_MAX_CELLS (%d): the tail was NOT "
                 "scored.  Raise the cap; do not report this aggregate.\n",
            (int)HET_STATS_MAX_CELLS);

  if (_s->flags & HET_ST_NO_DECODE_CHANNEL)
    fprintf(_ch, "  *** A CELL CARRIED NEITHER A SYNCHRONY NOR AN OBSERVER DECODE ***"
                 "  Its sightings cannot be checked for the constant-read artefact, "
                 "so they are treated as DEGENERATE.  This is a BUILD BUG (0 of the "
                 "338 should reach it).\n");

  if (_s->flags & HET_ST_WIN_DESYNC)
    fprintf(_ch, "  *** THE PER-WINDOW SUB-TALLIES DO NOT SUM TO THE CONTROL TOTAL ***"
                 "  The window bump is dead or mis-indexed, so every dispersion "
                 "number here would be fiction.  NO BOUND IS REPORTED.  Rebuild; do "
                 "not report.\n");

  if (_s->obs == HET_OBS_VOID) {
    fprintf(_ch, "  VOID -- not one of the %d runs was usable (every cell COLD).  "
                 "There is nothing here to bound: an empty histogram from a dead "
                 "harness is not a non-observation, it is an absence of data.  See "
                 "the per-run HetVerdict lines for which mechanism was dead.\n", _s->R);
    return;
  }

  /* ---- the dispersion, and what it did to the bound. */
  if (_s->flags & HET_ST_FANO_UNMEASURED) {
    fprintf(_ch, "  dispersion: NOT MEASURED (the control channel yielded no usable "
                 "per-window stream).\n"
                 "  *** NO FALSE-NEGATIVE BOUND IS REPORTED, and the textbook 3/N is "
                 "NOT substituted for one. ***  A bound that silently defaults to "
                 "Poisson is the textbook rule of three wearing a dispersion-aware "
                 "hat, and on a bursty channel it is a ~6x optimistic overclaim.\n");
  } else {
    fprintf(_ch,
      "  dispersion (from the %s channel, %d window samples): F_win = %.3f "
      "(Var %.3f / Mean %.3f), r_hat = %s, lag-1 acf = %.3f; F_cell = %.3f.\n",
      (_s->flags & HET_ST_CTRL_IS_CANARY) ? "Layer-B canary" : "mu(T) minimal mutant",
      _s->win_samples, _s->F_win, _s->ctrl_var, _s->ctrl_mean,
      (_s->r_hat >= HET_R_POISSON) ? "inf (Poisson)" : "finite (see HetStats line)",
      _s->acf1, _s->F_cell);
    if (_s->flags & HET_ST_TAU_UNMEASURED)
      fprintf(_ch,
        "  within-run correlation: tau NOT MEASURED -> each run counts as ONE "
        "trial (N_eff = 1).  That is B7's maximally conservative reading, kept "
        "because an unmeasured tau must never buy a tighter bound.\n");
    else if (_s->flags & HET_ST_TAU_UNRESOLVED)
      fprintf(_ch,
        "  within-run correlation: tau_w = %.2f window(s), but tau IS NOT RESOLVED "
        "-- the pooled control stream is only %d sample(s) long and an estimate of "
        "tau needs about %.0fx tau (= %.0f) behind it before it can be trusted.  "
        "N_eff FALLS BACK TO 1 (B7's one-bit-per-run reading): a tau we could not "
        "measure must never buy a tighter bound, exactly as a KS test that could "
        "not run must never unlock P_rep.\n"
        "  NOTE the direction: this estimator (Geyer initial-positive-sequence) "
        "UNDER-reads tau on a stream too short for it -- a spurious non-positive "
        "pair truncates the sum early -- so the number above is a FLOOR, it is NOT "
        "at the %d-window ceiling, and believing it would have OVER-credited N_eff "
        "and reported a bound TIGHTER THAN THE TRUTH.\n"
        "  THIS IS NOT A FAILURE AND NOT A VETO -- it is a PRICE, and the price is "
        "RUNS: the criterion is on the POOLED count (usable runs x %d windows), so "
        "it relaxes on its own.  Re-run this test with >= %d usable run(s) (it has "
        "%d) and N_eff becomes claimable.  Grow R, NOT N: extra iterations only add "
        "correlated frames inside the same alignment windows, while a fresh run adds "
        "a fresh phase/seed/thermal draw (Q3 F4).\n",
        _s->tau_w, _s->win_samples, (double)HET_TAU_MIN_SAMPLES,
        (double)HET_TAU_MIN_SAMPLES * _s->tau_w, (int)HET_NWIN, (int)HET_NWIN,
        _s->tau_runs_needed, _s->R_usable);
    else if (_s->flags & HET_ST_TAU_AT_CAP)
      fprintf(_ch,
        "  within-run correlation: tau_w = %.1f window(s) -- AT THE RESOLUTION "
        "CEILING (%d windows/run), and RESOLVED there (%d pooled samples >= %.0fx "
        "tau).  The alignment regime outlives the run at this window size, so one "
        "run IS one independent draw (N_eff = 1): B7's one-bit-per-run answer was "
        "right on this channel.  The remedy here is NOT more runs (this reading is "
        "already resolved) -- HET_NWIN is a SWEPT knob, so rebuild with a FINER "
        "resolution to probe whether the regime resolves.  (Contrast "
        "TAU_UNRESOLVED, whose remedy IS more runs.)\n",
        _s->tau_w, (int)HET_NWIN, _s->win_samples, (double)HET_TAU_MIN_SAMPLES);
    else
      fprintf(_ch,
        "  within-run correlation: tau_w = %.2f window(s) (Geyer "
        "initial-positive-sequence over the %d-window control stream) -> "
        "N_eff = %.1f effective independent samples per run, clamped to "
        "[1, %d] -- a stream of %d windows cannot witness more.  A correlated "
        "sequence is DISCOUNTED, not discarded: B7 scored each run as ONE "
        "Bernoulli bit, the tau = run-length worst case.\n",
        _s->tau_w, (int)HET_NWIN, _s->N_eff, (int)HET_NWIN, (int)HET_NWIN);
    if (_s->flags & HET_ST_CTRL_IS_CANARY)
      fprintf(_ch, "  NOTE: calibrated off the Layer-B canary, not this test's own "
                   "mu(T) -- a different SHAPE's burstiness.  Weaker than a "
                   "shape-matched calibration; say so when reporting.\n");
    if (_s->flags & HET_ST_UNDERDISPERSED)
      fprintf(_ch, "  NOTE: F_win < 1 (under-dispersed).  Clamped to the Poisson "
                   "floor: an under-dispersed sample is NOT allowed to make the "
                   "bound TIGHTER than the rule of three.\n");
    if (_s->flags & HET_ST_BURSTY)
      fprintf(_ch, "  BURSTY (F_win = %.2f >> 1): the rule-of-three constant 3 has "
                   "WIDENED to mu_upper = %.2f.  Reporting a bare p < 3/N here would "
                   "be a %.1fx optimistic overclaim.\n",
              _s->F_win, het_mu_upper(_s->r_hat),
              het_mu_upper(_s->r_hat) / (-log(0.05)));
  }

  /* ---- stationarity. */
  if (_s->flags & HET_ST_KS_UNDERPOWERED)
    fprintf(_ch, "  stationarity: NOT TESTED -- %s.  Fails CLOSED: P_rep is "
                 "suppressed exactly as it would be on a rejection, because a KS run "
                 "against an empty stream would `pass' without testing anything.\n",
            (_s->flags & HET_ST_FANO_UNMEASURED)
              ? "this harness has no live control stream to test (the two `self' "
                "canary rows co-run no control by construction, and a control that "
                "never fired leaves nothing to test either)"
              : "too few window samples");
  else if (_s->ks_pass)
    fprintf(_ch, "  stationarity: KS pass (D = %.4f <= D_crit = %.4f, %d early vs %d "
                 "late window counts).  On discrete counts the two-sample KS is "
                 "conservative, so this is the WEAKER of the two possible claims.\n",
            _s->ks_D, _s->ks_Dcrit, _s->ks_n_early, _s->ks_n_late);
  else
    fprintf(_ch,
      "  stationarity: *** KS REJECTED *** (D = %.4f > D_crit = %.4f).  The control "
      "rate is NOT stationary across the run: the change-point is near window %d of "
      "%d.  Kirkham's own precheck already fails 4/18 GPU-only chip/test "
      "combinations, and het adds warm-up, thermal drift and alignment drift on top.\n"
      "  P_rep is NOT reported across a non-stationary boundary (Q3 R4).  Re-run "
      "split at the change-point and score the segments separately -- Kirkham 5.1: "
      "\"non-stable runs can then be restarted from the point of instability\".\n",
      _s->ks_D, _s->ks_Dcrit, _s->ks_split_window, (int)HET_NWIN);

  /* ---- the headline, by observation class. */
  if (_s->obs == HET_OBS_NEVER) {
    if (_s->p_bound < 0.0) {
      fprintf(_ch, "  NOT OBSERVED in any of the %d usable cell(s) -- and NO BOUND "
                   "can be attached to it (see above).  Report the non-observation; "
                   "do NOT report a rate.\n", _s->R_usable);
    } else if (_s->flags & HET_ST_BOUND_VACUOUS) {
      fprintf(_ch,
        "  NOT OBSERVED in any of the %d usable cell(s) -- but THE BOUND IS VACUOUS:\n"
        "      p < mu_upper(r_hat) / R_eff = %.4g / %.2f = %.4g   >= 1\n"
        "  the bounded rate is a PROBABILITY, so a bound above 1 bounds NOTHING.  "
        "This is not a weak claim, it is the ABSENCE of one, and it must NOT be "
        "tabulated as a number.\n"
        "  WHY: the control channel is bursty (F_win = %.2f), so the process parks so "
        "much probability mass at zero that observing zero is nearly free.  That IS "
        "the finding -- and it is exactly the case in which a bare p < 3/N would have "
        "claimed a strong result from no evidence at all.\n"
        "  REMEDY (Q3 F4/R3): grow R -- more independent perpetual runs, each a fresh "
        "phase/seed/thermal draw -- NOT bigger N, which only adds correlated frames "
        "inside the same few alignment windows.\n",
        _s->R_usable, _s->mu_upper, _s->R_eff, _s->p_bound, _s->F_win);
    } else {
      double deff = (_s->F_cell > 1.0) ? _s->F_cell : 1.0;
      fprintf(_ch,
        "  NOT OBSERVED in any of the %d usable cell(s).  95%% upper bound on its "
        "rate PER EFFECTIVE SAMPLE (one tau_w-window alignment epoch):\n"
        "      p < mu_upper(r_hat) / R_eff = %.4f / %.2f = %.4g\n"
        "  (R_eff = %d usable runs x N_eff %.1f / DEFF %.2f.  The base unit is "
        "the (instance,run) CELL, NOT the frame -- the scan validates N^{T_L} "
        "overlapping frames per N iterations, so a frame count fed to 1-e^{-n} "
        "returns ~1 vacuously (PerpLE VI-B.1) -- and B7b DISCOUNTS the "
        "within-run stream by its measured autocorrelation instead of "
        "discarding it to one bit.)\n"
        "  implied RUN-level bound: p_run < N_eff x p = %.4g -- identical to "
        "B7's, BY CONSTRUCTION: the discount adds resolution beneath the "
        "run-level claim, it never tightens it for free.  The dividend is paid "
        "where the hours are: the budget below is met with N_eff-fold fewer "
        "runs.\n",
        _s->R_usable, _s->mu_upper, _s->R_eff, _s->p_bound,
        _s->R_usable, _s->N_eff, deff,
        _s->N_eff * _s->p_bound);
    }
    switch (_s->oracle) {
    case ORACLE_DISALLOWED:
      fprintf(_ch, "  This is the CMCM validation claim: forbidden, and not observed "
                   "under the effort above.  It is consistency evidence, NOT a "
                   "proof.\n");
      break;
    case ORACLE_ALLOWED:
      fprintf(_ch, "  OBSERVABILITY, NOT VALIDATION: the outcome is PERMITTED, so "
                   "this bound describes OUR HARNESS's reach on this hardware, not "
                   "the model.  It feeds B8's stress-tuning priority.\n");
      break;
    default:
      fprintf(_ch, "  CHARACTERIZATION, NEVER VALIDATION: the model is SILENT here, "
                   "so the bound describes the HARDWARE, and there is no prediction "
                   "for it to confirm or refute (Q4 R5).\n");
      break;
    }
    fprintf(_ch, "  effort: %d run(s) x N=%llu iterations, %llu frames examined.\n",
            _s->R_usable, (unsigned long long)_s->N,
            (unsigned long long)_s->frames_examined);

    /* R3 -- WAS THE EFFORT EVER SIZED?  A null is only meaningful against a budget: run
       enough cells that a behaviour as rare as the hardest one we CAN see would have
       shown up.  We cannot state that budget yet, and saying so is the honest move --
       an unsized null is not a wrong result, it is an unquantified one. */
    { double need = het_budget_runs((double)HET_P_MIN, _s->F_win);
      /* B7b: het_budget_runs sizes the budget in EFFECTIVE CELLS (its p_min is a
         per-effective-sample rate, measured from the ALLOWED-OBSERVED rows at
         the SAME HET_NWIN resolution -- a p_min measured at another window size
         is a different number).  Each usable run now supplies N_eff of them, so
         the RUN budget is need/N_eff: this division is where B7's
         1,500-30,000-run estimate shrinks, and it is exactly N_eff-fold. */
      if (need < 0.0)
        fprintf(_ch,
          "  budget: NOT SIZED.  p_min -- the per-effective-sample rate of the "
          "hardest het behaviour we can actually observe -- is HARDWARE-ONLY and "
          "unset (HET_P_MIN).\n"
          "          It is NOT Bagchi's ~0.2%%: that is the GPU-only INTER-CTA rate "
          "(their 5.1/4.1), which fires with no CPU participation and never crosses "
          "C2C.  There is no published numeric het hit-rate.\n"
          "          Derive it on GH200 from the ALLOWED-OBSERVED rows (they ARE the "
          "observed-rate population, at THIS HET_NWIN) and re-run with "
          "-DHET_P_MIN=<rate>.\n");
      else if ((double)_s->R_usable * _s->N_eff < need)
        fprintf(_ch,
          "  budget: UNDER-RUN.  %d usable run(s) x N_eff %.1f = %.0f effective "
          "cell(s), but %.0f are needed to have had a 95%% chance of catching a "
          "behaviour at p_min=%g (dispersion-inflated by F_win=%.2f) -- i.e. %.0f "
          "run(s) at this N_eff.\n"
          "          This null is NOT yet meaningful.  Grow R -- more independent runs "
          "-- NOT N (Q3 F4).\n",
          _s->R_usable, _s->N_eff, (double)_s->R_usable * _s->N_eff, need,
          (double)HET_P_MIN, _s->F_win, ceil(need / _s->N_eff));
      else
        fprintf(_ch,
          "  budget: MET.  %d usable run(s) x N_eff %.1f = %.0f effective cell(s) "
          ">= the %.0f needed for a 95%% chance of catching a behaviour at "
          "p_min=%g (F_win=%.2f).  Not seeing it after THAT is the claim.\n",
          _s->R_usable, _s->N_eff, (double)_s->R_usable * _s->N_eff, need,
          (double)HET_P_MIN, _s->F_win);
    }
    return;
  }

  /* ---- observed.  The denominator is R for a SELF-CONTROLLED row and R_usable for
     everything else -- see the selection effect in het_stats_compute. */
  { int denom = (_s->flags & HET_ST_SELF_CONTROL) ? _s->R : _s->R_usable;
    const char *unit = (_s->flags & HET_ST_SELF_CONTROL) ? "run" : "usable cell";
    if (_s->P_rep >= 0.0)
      fprintf(_ch, "  OBSERVED in %d of %d %s(s).  P_rep = 1 - e^{-k_eff} = "
                   "%.2f%% that a fresh run reproduces it (k_eff = %d NON-DEGENERATE "
                   "cells -- Kirkham's n=3 => 95%% recipe, relocated to the "
                   "(instance,run) unit).\n",
              _s->k, denom, unit, 100.0 * _s->P_rep, _s->k_eff);
    else
      fprintf(_ch, "  OBSERVED in %d of %d %s(s).  P_rep is NOT reported "
                   "(the process failed the stationarity gate, or no cell survived the "
                   "decode guard).\n", _s->k, denom, unit);

    if (_s->flags & HET_ST_SELF_CONTROL)
      fprintf(_ch,
        "  NOTE: this row CO-RUNS NO CONTROL -- it IS the Layer-B canary "
        "(control-map.csv says `self'), and a test cannot control itself (B6b).  A run "
        "in which it did not fire is therefore COLD and carries no information, so\n"
        "  \"usable cells\" is DEFINED BY firing.  The denominator above is R -- the "
        "runs executed -- not the usable count: otherwise a canary that fired in %d of "
        "%d runs would report ALWAYS, and that rate is precisely what the rest of the\n"
        "  campaign is calibrated against.  For the same reason this row has no "
        "independent channel to measure dispersion or stationarity against, so it gets "
        "NO BOUND -- by construction, not by omission.\n",
        _s->k, _s->R);
  }

  if (_s->flags & HET_ST_DEGEN_SIGHTING)
    fprintf(_ch,
      "  *** %d SIGHTING(S) CAME FROM A DEGENERATE CELL *** (distinct_decoded_iters "
      "< %d, or a decode that never varied).  Srivastava observed exactly this "
      "artefact -- a reader stuck on init or on one value yields a spurious "
      "100%%/0%%.\n"
      "  They are REPORTED, not discarded: falsification is one-sided and a genuine "
      "sighting refutes.  They just do not COUNT toward corroboration.\n",
      _s->n_degen, (int)HET_THETA_DISTINCT);

  if (_s->oracle == ORACLE_DISALLOWED) {
    if (_s->tier == HET_MT_CONFIRMED)
      fprintf(_ch,
        "  ** %s ** -- the should-be-FORBIDDEN outcome was observed in %d distinct "
        "non-degenerate RUN(S).  A decoder artefact does not reproduce across "
        "re-seeded runs, so this is a REFUTATION OF THE CMCM's PREDICTION and not a "
        "constant-read.  This is the campaign's most valuable output: report it.\n",
        het_tier_name(_s->tier), _s->k_runs);
    else
      fprintf(_ch,
        "  ** %s ** -- the should-be-FORBIDDEN outcome was observed, but in only %d "
        "clean run(s) (<3).  BELIEVE IT AND REPORT IT -- one sighting refutes, and it "
        "is NOT suppressed -- but a false MISMATCH is a false refutation of the "
        "compound model, the most damaging error this campaign can make.  REPRODUCE "
        "IT to >=3 clean runs before writing it up as a model violation.\n",
        het_tier_name(_s->tier), _s->k_runs);
  }
}

/* =========================================================================
 * B7b -- THE CAMPAIGN STOPPING RULE: where the GH200 hours are actually saved.
 *
 * Only 52 of the 338 tests need a bound at all: the 16 Disallowed (the CMCM
 * validation claim) and the 36 NO-ORACLE (characterization).  The 286 Allowed
 * just need to FIRE ONCE -- a positive is self-vouching (B6c ALLOWED-OBSERVED;
 * falsification and confirmation-from-below are one-sided) -- so running them
 * to a bound-grade budget burns ~6.5x the campaign time for nothing.  On top
 * of that, a bound-needing test stops the moment its bound is MET: most tests
 * converge early and only the stubborn shapes (Kirkham 4.2: SB is hardest on
 * every chip) need the long tail.  Do not run 30,000 runs on a test that
 * converged at 500.
 *
 * This is a PURE FUNCTION of the record stream, like het_verdict() and
 * het_stats_compute() before it -- so the driver's in-binary adaptive loop
 * (HET_ADAPTIVE=1) and hetlitmus/campaign.py's cross-invocation loop apply the
 * SAME policy, and statscheck.py can unit-test it from synthetic records.
 *
 * Per oracle class:
 *   ALLOWED     stop at the first CLEAN sighting (k_eff >= 1, not k >= 1: a
 *               sighting the decode guard rejected is possibly Srivastava's
 *               constant-read artefact, and an artefact must not de-schedule a
 *               test).  Its absence needs no bound -- an unobserved Allowed row
 *               is an observability datum for B8, priced by the budget cap.
 *   DISALLOWED  a sighting does NOT stop the test at 1: a MISMATCH must be
 *               corroborated to >=3 distinct clean runs (HET_MT_CONFIRMED)
 *               before the campaign moves on -- an uncorroborated refutation is
 *               the most damaging thing we could write up, so the scheduler
 *               ESCALATES it rather than banking it.  With no sighting, stop
 *               once the bound is met: p_bound valid, non-vacuous, <= p_goal.
 *   NO-ORACLE   same bound-met rule; a sighting is characterization and wants
 *               the full budget (a RATE needs more data than an existence).
 *   UNSET       fail closed: no early stop on a harness whose oracle tag is
 *               missing (het_verdict() already brands it a BUILD BUG).
 *
 * Stopping on a bound is NOT data-peeking in the Kirkham 5.1 sense: p_bound is
 * computed only over all-zero records and only shrinks as zero-runs accumulate,
 * so stopping when it first reaches p_goal reports a bound that holds at that
 * fixed sample size.  (Kirkham's caution targets tuning-parameter selection --
 * that is B8's problem, and B8 must use the EFFECTIVE sample count in its CI.)
 *
 * B7c -- WHAT AN UNRESOLVED tau DOES HERE, AND WHY IT IS THE POINT.  This is where
 * an over-credited N_eff would actually have SPENT the error: a tau under-read by
 * the estimator inflates N_eff, shrinks p_bound, and the row hits p_goal and STOPS
 * EARLY -- the campaign banks a bound it never earned and moves the GH200 hours
 * somewhere else.  With the guard, an unresolved tau scores N_eff = 1, p_bound is
 * B7's (wider) number, the goal is NOT met, and the row KEEPS RUNNING.  So the
 * scheduler needs no special case: HET_ST_TAU_UNRESOLVED is
 *   - never a STOP: it is not a failure, and nothing here branches on it;
 *   - never a VETO: a BOUND-MET earned while it is set was earned on the
 *     CONSERVATIVE (N_eff = 1) reading, so it is honest and must stand;
 *   - self-clearing: the criterion is on the POOLED count (usable runs x HET_NWIN),
 *     and HET_ADAPTIVE re-runs het_stats_compute() after every run, so nwin grows
 *     as the invocation proceeds and the guard can lift itself mid-run.
 * The one thing it must NOT be is silent: st.tau_runs_needed prices it in runs, and
 * both het_stats_line() (tau_need=) and het_stats_print() report it, so an operator
 * (and hetlitmus/campaign.py) can see that this row's N_eff is unclaimable at the
 * run count it was given -- and exactly what it would cost to claim it.
 *
 * p_goal <= 0 means "no bound target": bound rows then run to budget.  There is
 * NO default p_goal baked in here -- a stopping target is a campaign decision,
 * like p_min, not a header constant. */
typedef enum {
  HET_CAMPAIGN_CONTINUE = 0,
  HET_CAMPAIGN_STOP_OBSERVED,    /* Allowed row fired cleanly: self-vouching     */
  HET_CAMPAIGN_STOP_CONFIRMED,   /* Disallowed row corroborated to >=3 runs      */
  HET_CAMPAIGN_STOP_BOUND_MET,   /* null row: p_bound <= p_goal                  */
  HET_CAMPAIGN_STOP_BUDGET       /* budget exhausted (the only stop with nothing
                                    to show; the verdict says what it means)     */
} het_campaign_stop_t;

static const char *het_campaign_stop_name(het_campaign_stop_t s) {
  switch (s) {
  case HET_CAMPAIGN_STOP_OBSERVED:  return "OBSERVED";
  case HET_CAMPAIGN_STOP_CONFIRMED: return "CONFIRMED";
  case HET_CAMPAIGN_STOP_BOUND_MET: return "BOUND-MET";
  case HET_CAMPAIGN_STOP_BUDGET:    return "BUDGET";
  default:                          return "CONTINUE";
  }
}

static het_campaign_stop_t het_campaign_should_stop(const het_obs_record *recs,
                                                    int n, int budget,
                                                    double p_goal) {
  het_stats_t st;
  if (n <= 0) return HET_CAMPAIGN_CONTINUE;
  het_stats_compute(recs, n, &st);
  switch (st.oracle) {
  case ORACLE_ALLOWED:
    if (st.k_eff >= 1) return HET_CAMPAIGN_STOP_OBSERVED;
    break;
  case ORACLE_DISALLOWED:
    if (st.tier == HET_MT_CONFIRMED) return HET_CAMPAIGN_STOP_CONFIRMED;
    /* p_bound >= 0 already implies obs == NEVER (it is computed nowhere else);
       the k == 0 guard restates it so the policy reads as it is meant. */
    if (st.k == 0 && p_goal > 0.0 && st.p_bound >= 0.0
        && !(st.flags & HET_ST_BOUND_VACUOUS) && st.p_bound <= p_goal)
      return HET_CAMPAIGN_STOP_BOUND_MET;
    break;
  case ORACLE_NONE:
    if (st.k == 0 && p_goal > 0.0 && st.p_bound >= 0.0
        && !(st.flags & HET_ST_BOUND_VACUOUS) && st.p_bound <= p_goal)
      return HET_CAMPAIGN_STOP_BOUND_MET;
    break;
  default:
    break;
  }
  if (budget > 0 && n >= budget) return HET_CAMPAIGN_STOP_BUDGET;
  return HET_CAMPAIGN_CONTINUE;
}

#endif /* HET_VERDICT_H */
