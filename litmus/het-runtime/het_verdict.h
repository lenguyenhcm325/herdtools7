/* =========================================================================
 * het_verdict.h -- HetLitmus observation record + null-credibility rule.
 * litmus7 copies this file verbatim into every emitted harness dir: edit
 * litmus/het-runtime/het_verdict.h, never a harness-dir copy.
 *
 * This harness REPORTS what it observed.  It carries no prediction and never
 * says a result contradicts a model.  A non-observation is evidence only if the
 * harness would have shown a weak behaviour had one occurred, so every null is
 * gated on a positive control that fired in the same launch, on the same C2C
 * path, under the same stress -- and both layers are heterogeneous themselves,
 * since a GPU-only (or CPU-only) known-weak behaviour vouches for the on-die
 * window, not the interconnect one.
 *   Layer A  mu(T)   a strictly weaker, structurally identical sibling of T,
 *                    co-running on the same launch -- from control-map.csv.
 *   Layer B  canary  a fixed het MP-{cg,gc}-sys-relaxed instance.
 * A control does not make a null a proof; it makes it credible-not-observed
 * instead of UNINTERPRETABLE.  Falsification is one-sided (Alglave et al.,
 * ASPLOS'15 4.3 p.585: "the possibility, not probability ... is what matters").
 * Design: hetlitmus/docs/positive-control.md.
 * Spec:   env-research/Q4-positive-control.md.
 * ========================================================================= */
#ifndef HET_VERDICT_H
#define HET_VERDICT_H

#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>   /* qsort: the two-sample KS stationarity precheck           */
#include <string.h>   /* strcmp: distinguishing the `self' canary from a missing one */
#include <math.h>

/* ---------------------------------------------------------------------------
 * WHICH MACHINE THIS HARNESS MAY NAME.  Every word below is a claim about
 * silicon, so none of it is derived here: the emitter stamps these defines from
 * the MACHINE TABLE row (litmus/hetMachine.ml), the only place that knows
 * what (CPU ISA x GPU dialect) this harness was built for.  An unregistered pair
 * stamps nothing and these defaults stand; they name the MECHANISM rather than a
 * brand, so a missing stamp can only weaken a claim, never invent one.
 * Rationale and the defect it closes: hetlitmus/docs/het-emission.md.
 * ------------------------------------------------------------------------- */
#ifndef HET_LINK_NAME       /* no leading article: use sites supply their own */
#define HET_LINK_NAME "host-device interconnect"
#endif
#ifndef HET_HOST_HALF
#define HET_HOST_HALF "the host half"
#endif
#ifndef HET_DEV_HALF
#define HET_DEV_HALF "the device half"
#endif
/* Alglave ASPLOS'15 4.3.1's "zero without stress" is an NVIDIA measurement (B4).
   1 only on a machine it was measured on; everywhere else the run is told that
   no equivalent figure exists rather than being handed somebody else's. */
#ifndef HET_ALGLAVE_ZERO_MEASURED
#define HET_ALGLAVE_ZERO_MEASURED 0
#endif
/* The page-placement lever HET_PLACE drives, by its API name.  A DIALECT fact:
   the CUDA render calls cudaMemAdvise, the HIP render carries no placement code
   at all (and #errors on a non-zero HET_PLACE), so there the mechanism is
   named and no API is claimed. */
#ifndef HET_PLACE_LEVER
#define HET_PLACE_LEVER "the page-placement lever"
#endif

/* ---------------------------------------------------------------------------
 * TWO BUILD FACTS, also stamped by the emitter and from EVERY pair: what this
 * binary was built for, and whether a positive-control map was read for it.  The
 * map is looked for beside every test, so HET_NO_CONTROL_MAP means it was not
 * there: nothing in such a harness marks any row the Layer-B canary, and its
 * missing bound is a BUILD FAULT rather than a construction.  The defaults below
 * are for the checkers, which compile this header standalone.
 * ------------------------------------------------------------------------- */
#ifndef HET_PAIR_NAME
#define HET_PAIR_NAME "(unstamped CPU ISA x GPU dialect pair)"
#endif
#ifndef HET_NO_CONTROL_MAP
#define HET_NO_CONTROL_MAP 0
#endif

/* tau_hot -- how many control sightings make the harness "demonstrably hot".
   3 is Kirkham's 95% floor (P_rep = 1 - e^-3 = 95.02%; OOPSLA'20 1.1); 30 makes
   "hot" comfortable rather than marginal, which is cheap in a perpetual harness.
   The calibration is hardware-only (Q4 8.1), and the Poisson arithmetic behind
   the floor assumes a stationarity that het drift can break -- which is why
   control_Prep below is a hotness indicator and not a guarantee. */
#ifndef HET_TAU_HOT
#define HET_TAU_HOT 30
#endif

/* ---------------------------------------------------------------------------
 * Knobs of the statistics layer (see its banner further down; Q3-stats.md 6.3).
 *
 * HET_NWIN.  The recovery scan buckets each run's frames into HET_NWIN windows
 * and sub-tallies the CONTROL channel per window -- the only within-run time
 * series the record carries, consumed by F_win, the lag-1 autocorrelation and the
 * KS precheck.  It is also a RESOLUTION FLOOR: the window is the finest time-scale
 * the record can see, so tau (het_tau_ips) cannot resolve below one window and
 * N_eff is clamped to [1, HET_NWIN].  128 windows is 781 iterations/window at the
 * default N.  The knob is SWEPT (-DHET_NWIN=...), not tuned here -- too fine and
 * adjacent windows correlate, tau_w rises and the gain cancels, and finding that
 * point is the estimator's job.  Every run reports the value it realised
 * (het_obs_record.nwin, nwin= in the HetStats line), so records scored at
 * different resolutions are never pooled.  Rationale: B7b-impl-brief.md.
 *
 * HET_THETA_DISTINCT (theta_d) is the degeneracy guard's floor
 * (het_cell_degenerate).  Deliberately the literal floor -- 2 = "the decode
 * produced at least two distinct values" -- not a statistical filter: it catches
 * Srivastava's constant-read artefact, and rejecting more than that discards
 * genuine sightings, which one-sided falsification forbids.  Raising it is a
 * hardware-calibration decision. */
#ifndef HET_NWIN
#define HET_NWIN 128
#endif
#ifndef HET_THETA_DISTINCT
#define HET_THETA_DISTINCT 2
#endif
/* Cells (instance,run) the aggregate can hold.  NUMBER_OF_RUN is 10 by default;
   a campaign that exceeds this is truncated and says so (HET_ST_CELLS_TRUNCATED)
   rather than silently scoring a subset. */
#ifndef HET_STATS_MAX_CELLS
#define HET_STATS_MAX_CELLS 128
#endif
/* ---------------------------------------------------------------------------
 * HET_P_MIN -- the run-level hit-rate of the hardest het behaviour this harness has
 * actually observed.  It sizes the campaign (het_budget_runs): run enough
 * near-independent cells that, had the target's rate equalled that hardest behaviour,
 * we would have had a 95% chance to catch it.
 *
 * It is 0 = unset, and stays so until the target this binary was built for measures
 * it.  DO NOT seed it with Bagchi's ~0.2%: that is the GPU-only inter-CTA rate
 * (ISMM'26 5.1 p.74, from their 4.1 results -- producer and consumer both GPU threads
 * on different CTAs), so it fires with no CPU participation and never crosses the
 * interconnect, and the paper publishes no numeric het rate at all (Table 4 is
 * qualitative).  Full reading: Q4-positive-control.md 2.1.
 * Derive it here instead from the rows this target DID exhibit, which are the
 * observed-rate sample; until then p_min is a symbol and het_budget_runs() answers
 * "NOT SIZED". */
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
 * HET_TAU_MIN_SAMPLES -- the reliability threshold on tau itself: "you probably
 * shouldn't trust any estimate of tau unless you have more than F x tau samples
 * for some F >= 50" (Foreman-Mackey et al., emcee, PASP 125:306, 2013, whose
 * integrated_time(tol=50) raises rather than warns).  Below it tau is NOT
 * RESOLVED and buys nothing: N_eff falls back to 1, the one-bit-per-run reading,
 * exactly as a KS test that could not run must never unlock P_rep.  The
 * threshold transfers between estimators; emcee's bias direction does not
 * (theirs is Sokal windowing; het_tau_ips is Geyer IPS and under-reads instead,
 * and an under-read tau over-credits N_eff and tightens the bound).
 *
 * Known-open (deep-review F8; env-research/decisions/F8-decision.md): the
 * threshold scales by the ESTIMATED tau, so a count-valued bursty stream can
 * vouch for itself and slip past it -- up to ~5x over-credit at R = 10 (witness:
 * statscheck.py COX_ESCAPE), against ~1.7x for estimates that clear it honestly.
 * Uncorrected by choice, a bias correction being estimator-specific: the
 * run-level bound is invariant to N_eff by construction (section 7 below), the
 * escape closes at R >= 50 usable runs, and 00-environment-design.md 6 makes any
 * early stop below R = 50 provisional.  The stress tuner must read an in-band
 * N_eff as accurate to a factor, not to a digit. */
#define HET_TAU_MIN_SAMPLES 50.0

typedef enum { CONF_ROBUST, CONF_ADVISORY, CONF_EXPLORATORY } het_confidence;

/* ---------------------------------------------------------------------------
 * THE RECORD STAMP.  het_obs_record is memset(0) before the emitted driver fills
 * it, so a zeroed record is exactly what an emitter that skipped a field would
 * produce.  rec_magic is the one field a zeroed record cannot forge: het_verdict()
 * refuses to read a record that does not carry it, and a harness whose stamp went
 * missing reports a build bug instead of a result.  The emitter writes the SYMBOL,
 * so a divergence between it and this header is a compile error, not a silent
 * mis-read (hetlitmus/verify/recfields.py checks the field names too). */
#define HET_REC_MAGIC 0x48455431u

/* Which stress mechanisms this BUILD asked for.  A mechanism that produced zero
   work is dead only if it was requested: a deliberately disabled one is not a
   bug, and without the distinction a no-stress baseline run would be COLD
   forever.  The emitter fills this from the compile-time knobs, which is what
   keeps the verdict a pure function of the record (and so unit-testable from
   synthetic records -- hetlitmus/verify/verdictcheck.py). */
#define HET_REQ_GPU_STRESS  (1u << 0)   /* HET_PRE_STRESS_PCT | HET_MEM_STRESS_PCT */
#define HET_REQ_SPIN        (1u << 1)   /* HET_BARRIER_PCT -> spin_rendezvous+cap  */
#define HET_REQ_CPU_ENEMY   (1u << 2)   /* HET_CPU_ENEMIES                         */
#define HET_REQ_CPU_PRELOAD (1u << 3)   /* HET_CPU_PRELOAD_PCT && _PRELOAD_LIVE    */
#define HET_REQ_NOISE_CPU   (1u << 4)   /* HET_NOISE_CPU                           */
#define HET_REQ_NOISE_GPU   (1u << 5)   /* HET_NOISE_GPU_BLOCKS                    */

typedef struct het_obs_record {
  /* HET_REC_MAGIC, or this record is not read at all -- see the stamp above. */
  uint32_t rec_magic;
  const char *test_name; int instance_id; int run_id;
  /* D10 (memo 7.D10): 1 when EVERY proc of this test is a CPU proc.  Such a test
     exercises no cross-device path at all -- it is an x86-TSO probe on the shared
     allocation -- so what its sighting is about is not what a het cycle's is, and
     the printout says so. */
  int cpu_only;
  /* WHICH observer channel recovered the `co' edge, on the shapes decoded by an
     observer.  Both 0 on a shape with a reader (there is no observer decode) and
     on a run where nothing fired.  They matter under cpu_only: x86-TSO
     constrains how x86 AGENTS observe two x86 stores, and the GPU observer is
     not one, so a sighting carried by obs_ws_via_gpu alone says nothing about
     x86-TSO.  Written by the emitted recovery scan, for the test under study. */
  int obs_ws_via_cpu;
  int obs_ws_via_gpu;
  /* THE BUILD FACTS the "structurally absent stress" caveat asserts, carried
     rather than inferred.  HET_GPU_LANES guards het_do_stress's round loop
     (`_gpu_done < HET_GPU_LANES') and HET_SPIN_LANES the device-scope window
     opener; at 0 the loop exits before its body runs once, which is why the
     emitter withholds the corresponding stress REQUEST there.
     They are NOT a synonym for cpu_only, and keying the caveat on cpu_only was
     a FALSE claim about the build: MEASURED 2026-08-03 over the emitted D10
     corpus, 2+2W-cpuonly-x86_64 and R-cpuonly-x86_64 have HET_GPU_LANES=1 (a
     GPU observer lane) while the other four have 0; all six have
     HET_SPIN_LANES=0.  The old caveat told the reader "HET_GPU_LANES is 0 ...
     neither mechanism is counted as requested" on a run whose own config line
     said stress_requested carried HET_REQ_GPU_STRESS. */
  int gpu_lanes;
  int spin_lanes;
  /* MECHANISM tier: how well this test's cycle can be recovered from the read
     and observer buffers (hetCond.perpetual_class). */
  het_confidence confidence;
  /* REPORTING tier: what a null from this test may be claimed as.  Not the
     mechanism tier -- R is mechanically Advisory but borrows both its synchrony
     point and its ws edge from the fragile observer, so it reports at the 2+2W
     floor.  Classifier and rationale: litmus/hetCond.mli, B3-decision 4.2. */
  het_confidence reporting;
  uint64_t N, frames_examined;
  uint64_t target_count_exhaustive, target_count_heuristic;
  /* 0 = the O(N^T_L) ground-truth scan did NOT run at this N (capped by
     HET_EXHAUSTIVE_MAX), so target_count_exhaustive is "not measured", NOT a
     measured zero; reading it as data would manufacture a false "Never".
     het_verdict() refuses HET_NOT_OBSERVED_MU_HOT when this is 0.  On a T_L<=1 shape
     (no windowed proc) every frame is decoded exactly, the O(N) scan is the
     ground truth, and the flag is 1 whatever N is. */
  int exhaustive_valid;
  uint64_t interleavings_detected;
  uint64_t distinct_decoded_iters;
  uint64_t ws_edges_via_observer;
  uint64_t observer_unique_count;
  int32_t skew_min, skew_max; double skew_mean, skew_stddev;
  /* Which decode channel this test HAS, so the degeneracy guard can switch
     channel instead of firing blind (het_cell_degenerate).  distinct_decoded_iters
     and skew_stddev are both written from the synchrony-decode block, so a
     store-only shape (2+2W: no reader at all) leaves both at their memset zero;
     read blind, that zero would condemn every one of those cells forever.  Same
     rule as exhaustive_valid: 0 means not measured.  The emitter sets these from
     the instance it compiled; every test has at least one channel and a record
     with neither fails closed. */
  int sync_valid;   /* 1 => distinct_decoded_iters + skew_* are populated */
  int obs_valid;    /* 1 => observer_unique_count is populated            */
  /* The positive control (Q4 3.2): control_* = Layer A, the minimal mutant mu(T)
     of THIS test; canary_* = Layer B, the universal het MP floor.  Both are
     tallied by the same recovery scan as target_count, on disjoint
     cache-line-padded locations, in the same launch under the same stress -- a
     control that ran at another time under another stress roll certifies nothing
     about this window (Kirkham 4.3: the rate is not stationary even within one
     run). */
  uint64_t control_target_count;
  uint64_t control_frames_examined;
  uint64_t canary_target_count;
  uint64_t canary_frames_examined;
  /* Which kind of count you are reading, per co-running instance: each has its own
     T_L class, and a T_L>=2 mutant (mu(SB-*-sys-fence-2s) is SB-*-sys-acqrel-2s)
     is counted by the WINDOWED scan at production N.  Windowed hits are a strict
     subset of the ground-truth scan's under the same predicate -- it can miss
     cycles, it cannot invent them -- so the control under-counts, which errs
     toward COLD.  het_verdict() deliberately does not gate the control on these:
     a control that cannot fire is not a control (positive-control.md 5). */
  int control_exhaustive_valid;
  int canary_exhaustive_valid;
  /* Per-window sub-tallies of the CONTROL channel (Q3 6.3): each control sighting
     is tallied into the window its frame fell in.  Every dispersion and
     stationarity estimate in the statistics layer is computed from them -- F_win
     (-> r_hat), the lag-1 autocorrelation, tau_w and the KS split.  The control,
     never the target: the target is far too rare to estimate a variance from
     (which is why it needs a bound at all), while the control is a high-rate proxy
     on the same fabric in the same run under the same stress.
     They are bumped on the same line, under the same predicate, as
     control_target_count / canary_target_count, so sum(control_win[]) ==
     control_target_count is an invariant the aggregate checks on every cell
     (HET_ST_WIN_DESYNC).  That is the one run-time check on real hardware that
     these tallies are alive at all: a dead-code-eliminated or mis-indexed bump
     breaks the sum, and every dispersion number would otherwise be fiction. */
  uint32_t control_win[HET_NWIN];
  uint32_t canary_win[HET_NWIN];
  /* 1 - e^{-control_target_count} (Kirkham's reproducibility score), kept only as
     the hot/cold light het_print_liveness prints.  IT IS NOT A CONFIDENCE: the
     count is of validated frames, of which the scan validates N^{T_L} overlapping
     ones per N iterations (PerpLE VI-B.1), so feeding it to 1 - e^{-n} drives the
     score to 1 vacuously -- the frame combinatorics inflate n.  The statistics
     layer below reports P_rep from the (instance,run) cell instead. */
  double control_Prep;
  /* 0 => no Layer-A mutant was compiled in, so control_target_count is
     structurally zero and means nothing.  1 => a real mu(T) is co-running here,
     same launch, same stress, same C2C path.  It is 1 on exactly the tests the
     control map names a strictly weaker structural sibling for; a test already at
     the lattice floor has none (MC-Mutants 1.2, Q4 4.2).  Kept separate from the
     canary flag below on purpose -- "a canary is co-running" and "the mutant OF
     THIS TEST is co-running" are different claims, and only the second says this
     shape's own window was demonstrably hit. */
  int control_compiled_in;
  /* 0 => no Layer-B canary is co-running, so canary_target_count is structurally
     zero and means nothing.  1 => a real canary instance is in this launch.  Set
     from the emitted instance population, not from the map: canary_name is
     non-NULL even where no canary co-runs, and a name is not a co-run.
     0 on exactly the two tests that ARE the canary (control-map.csv says `self')
     and so cannot co-run themselves; when one of them does not fire, nothing here
     can vouch for it and COLD-INVALID is the correct answer, not a gap. */
  int canary_compiled_in;
  const char *control_name;   /* mu(T), from tests/het/control-map.csv */
  const char *canary_name;    /* the Layer-B canary -- NAMED for every test */
  /* GPU stress liveness.  The stress layer is invisible to the L0 faithfulness
     gate by design, so its health is known only if it is MEASURED at run time.
       spin_rendezvous/spin_cap  how the window-opener's spins ended; a mostly
                         cap-released spin is a delay loop, not a rendezvous, and
                         the tuner reads HET_BARRIER_PCT against this ratio.
       stress_truncated  lanes that hit HET_STRESS_MAX_ROUNDS, i.e. stopped
                         stressing while the test still ran.  Disqualifying: such
                         a run's non-observations are not a stressed run's.
       gpu_stress_rounds max rounds any single het_do_stress call completed.  A
                         co-run harness reserves 3x-5x the test blocks, so the
                         stress population is the first thing a co-residency cap
                         squeezes to zero -- code present, requested, run by
                         nobody. */
  uint64_t spin_rendezvous, spin_cap, stress_truncated;
  uint64_t gpu_stress_rounds;
  /* CPU + interconnect liveness.  Same argument, for the two levers the GPU
     tallies above do not cover; each field measures a mechanism with a plausible
     way to die silently:
       cpu_enemy_rounds  0 => the CPU enemies never ran (stress_go ordering, or a
                         loop the optimiser deleted).
       cpu_preload_ops   0 => the M3 incantation is inert (a host with no cache
                         primitives, or a 0% roll).
       noise_cpu_rounds  0 => the host half of the interconnect noise never ran;
       noise_gpu_blocks  0 => the device half never ran.  Either way the run is NOT
                         interconnect-stressed, whatever HET_NOISE_* claimed.
                         (Both halves are NAMED by HET_HOST_HALF/HET_DEV_HALF,
                         stamped from the pair row.)
       cpu_aff_failures >0 => sched_setaffinity FAILED: the threads are wherever the
                         scheduler put them and the pinning is fiction.
       place_failures   >0 => HET_PLACE_LEVER was REFUSED: HET_PLACE placed nothing.
     A target count from a run whose stress was inert is not the same datum as one
     from a stressed run, and nothing else in this record would say so. */
  uint64_t cpu_enemy_rounds, cpu_enemy_accesses, cpu_preload_ops;
  uint64_t noise_cpu_rounds, noise_cpu_words;
  uint32_t noise_gpu_blocks, noise_gpu_rounds;
  uint32_t cpu_enemies, cpu_aff_failures, place_failures;
  /* The two knobs the tuner drives the interconnect lever with, carried per run so
     it reads what the run REALISED, not what it asked for.  noise_ws_mb is the
     noise working set, and it decides whether the noise crosses anything at all:
     below the last-level cache the buffer is served from cache and generates no
     interconnect traffic, so a config that scores well at 8 MB scored a stressor
     that was not running (Q6 3).  The argument is target-independent; the FIGURE is
     not, and the emitter stamps the pair's own into HET_LLC_MB. */
  uint32_t noise_ws_mb, place_mode;
  /* The window resolution this run realised (= HET_NWIN of the binary that
     produced it).  HET_NWIN is swept and tau_w/F_win are resolution-dependent
     (N_eff's clamp ceiling IS nwin), so records scored at different resolutions
     must never be pooled -- campaign.py refuses to. */
  uint32_t nwin;
  uint32_t stress_requested;    /* HET_REQ_* bitmask -- see above */
} het_obs_record;

/* Frame index -> window bucket, called from the recovery scan on the SAME line as
   the control's count bump.  Being a function of the frame index, there is nothing
   here the optimiser can fold away -- unlike a -D knob threaded through an
   if-chain, which is how the stress layer once got deleted silently.  Clamped
   rather than asserted: an out-of-range bucket must not corrupt the record, and
   the sum-vs-total invariant would catch a mis-index anyway. */
static int het_win_of(long f, long n) {
  long w;
  if (n <= 0) return 0;
  w = (f * (long)HET_NWIN) / n;
  if (w < 0) w = 0;
  if (w >= HET_NWIN) w = HET_NWIN - 1;
  return (int)w;
}

/* ---------------------------------------------------------------------------
 * RUNTIME knobs: getenv, never a -D the device code can see (nvcc folds a
 * compile-time knob and removes the only branch with side effects).  These are
 * host-side reads the campaign scheduler (hetlitmus/campaign.py) retunes per
 * invocation without a rebuild:
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
 * Unset => the compiled default, so a bare ./run behaves exactly as a build with
 * no scheduler in front of it. */
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
 * THE OUTCOME.  One axis -- was the weak outcome seen, and if not, what vouches
 * for the harness that did not see it.  No prediction enters here and none is
 * printed: "observed" and "not observed" are the whole vocabulary, and what they
 * are worth against any model is settled offline (hetlitmus/oracle-compare.sh).
 *
 *   HET_OBSERVED    seen.  Believed unconditionally -- falsification is one-sided,
 *                   so no control is needed to believe a positive.
 *   HET_NOT_OBSERVED_MU_HOT       not seen, and mu(T) -- a strictly weaker,
 *                   structurally identical sibling on the same launch, stress and
 *                   C2C path -- fired >= tau_hot while T's own two engines
 *                   provably overlapped, with the ground-truth scan running.
 *   HET_NOT_OBSERVED_CANARY_ONLY  not seen on a harness that is alive but whose
 *                   OWN shape is not confirmed hit: only the Layer-B canary
 *                   vouches, or no mu co-runs, or the zero came from the windowed
 *                   scan.  Weaker; the printout names which (Alglave's GTX-280
 *                   honesty, fn.7 p.577, is the precedent for saying so plainly).
 *   HET_COLD_INVALID  not demonstrably hot, or the record is unstamped.  The empty
 *                   histogram carries no information: discard it, never report it
 *                   as "not observed".
 * ------------------------------------------------------------------------- */
typedef enum {
  HET_OBSERVED = 0,
  HET_NOT_OBSERVED_MU_HOT,
  HET_NOT_OBSERVED_CANARY_ONLY,
  HET_COLD_INVALID
} het_verdict_t;

/* Why a run was DISQUALIFIED (its null is discarded).  Each names a mechanism
   that is dead, not merely suboptimal. */
#define HET_DQ_NO_CONTROL_BUILT (1u << 0)  /* neither layer compiled in           */
#define HET_DQ_NO_INTERLEAVING  (1u << 1)  /* the two engines never overlapped    */
#define HET_DQ_CONTROLS_COLD    (1u << 2)  /* neither mu(T) nor the canary fired  */
#define HET_DQ_STRESS_TRUNCATED (1u << 3)  /* stress stopped mid-run              */
#define HET_DQ_SPIN_DEAD        (1u << 4)  /* window-opener requested, never spun */
#define HET_DQ_CPU_ENEMY_DEAD   (1u << 5)
#define HET_DQ_CPU_PRELOAD_DEAD (1u << 6)
#define HET_DQ_NOISE_CPU_DEAD   (1u << 7)  /* NOT interconnect-stressed           */
#define HET_DQ_NOISE_GPU_DEAD   (1u << 8)
#define HET_DQ_GPU_STRESS_DEAD  (1u << 9)  /* het_do_stress requested, never ran  */
/* Unstamped record: rec_magic is missing, so the fields below it are whatever the
   emitter left there -- a zeroed record reads as a live one.  Fail closed, loudly. */
#define HET_DQ_REC_UNSTAMPED    (1u << 10)
/* The observer channel (a store-only shape's only one) resolved fewer than
   HET_THETA_DISTINCT distinct GPU store-values -- its analogue of
   interleavings_detected == 0.  A separate code, not a reuse of NO_INTERLEAVING,
   so the printed sentence names the channel that actually failed. */
#define HET_DQ_OBSERVER_COLD    (1u << 11)

/* Why a null was CAVEATED (still reportable, but weaker than it looks). */
#define HET_CV_NO_EXHAUSTIVE    (1u << 0)  /* ground-truth scan did not run       */
#define HET_CV_CANARY_ONLY      (1u << 1)  /* Layer B fired, Layer A did not      */
#define HET_CV_HEURISTIC_SIGHT  (1u << 2)  /* sighting via the windowed heuristic */
#define HET_CV_AFF_FAILED       (1u << 3)  /* pinning is fiction                  */
#define HET_CV_PLACE_REFUSED    (1u << 4)  /* HET_PLACE_LEVER placed nothing      */
#define HET_CV_SPIN_CAP         (1u << 5)  /* a delay loop, not a rendezvous      */
#define HET_CV_UNSTRESSED       (1u << 6)  /* no stress requested at all          */
#define HET_CV_NO_GPU_LANES     (1u << 7)  /* D10: a CPU-only harness has no GPU
                                              test lane, so the GPU scratchpad
                                              stress and the device-scope
                                              window-opener are STRUCTURALLY
                                              absent -- not dead, absent.  The
                                              null rests on CPU-side stress
                                              alone and must say so.            */

static int het_dead(uint32_t req, uint32_t bit, uint64_t rounds) {
  return (req & bit) && rounds == 0;
}

/* The rule (Q4 3.3, plus the exhaustive_valid gate and the stress-liveness
   disqualifiers).  A pure function of the record. */
static het_verdict_t het_verdict(const het_obs_record *r,
                                 uint32_t *dq_out, uint32_t *cv_out) {
  uint32_t dq = 0, cv = 0;
  uint32_t req = r->stress_requested;
  het_verdict_t v;
  int hot_control, hot_canary;

  /* Each layer is gated on ITS OWN compiled-in flag: most harnesses co-run a
     canary and no mutant, and gating the canary on the mutant's flag would make
     their liveness evidence invisible. */
  hot_control = (r->control_compiled_in && r->control_target_count >= HET_TAU_HOT);
  hot_canary  = (r->canary_compiled_in  && r->canary_target_count  >= HET_TAU_HOT);

  /* ---- 0. FAIL CLOSED on an unstamped record, before anything else: every field
     below is then whatever memset left, so every sentence we could print would be
     read off zeros.  Reachable only through an emitter bug, which is why it is a
     visible stop and not a default frame. */
  if (r->rec_magic != HET_REC_MAGIC) {
    if (dq_out) *dq_out = HET_DQ_REC_UNSTAMPED;
    if (cv_out) *cv_out = 0;
    return HET_COLD_INVALID;
  }

  /* ---- 1. The caveats are computed FIRST, because a SIGHTING needs them too: a
     weak behaviour observed under a stress config nobody recorded is not
     reproducible.  (The stress incantations travel with the sighting for the same
     reason Alglave et al. report absolute counts per incantation combination --
     ASPLOS'15 4.3 p.585, Tab.6.)  The outcome is unchanged; only its provenance
     travels. */
  if (!r->exhaustive_valid)         cv |= HET_CV_NO_EXHAUSTIVE;
  /* "Layer B fired, Layer A did not" is a caveat only where a Layer A exists to
     have not fired.  Without the control_compiled_in guard it would be raised on
     every test at the lattice floor -- which has no mutant by construction --
     turning a real diagnostic into boilerplate on most of the corpus. */
  if (r->control_compiled_in && !hot_control && hot_canary)
                                    cv |= HET_CV_CANARY_ONLY;
  if (r->cpu_aff_failures > 0)      cv |= HET_CV_AFF_FAILED;
  if (r->place_failures > 0)        cv |= HET_CV_PLACE_REFUSED;
  if (req == 0)                     cv |= HET_CV_UNSTRESSED;
  /* D10.  The emitter withholds HET_REQ_GPU_STRESS / HET_REQ_SPIN on a harness
     whose corresponding lane count is 0, because there the mechanism is
     structurally unreachable rather than dead.  Withholding a request silently
     would be the "bump the threshold to get green" move, so it is CAVEATED here
     instead: the reader is told which window-openers could not have run.
     KEYED ON THE LANE COUNTS THE EMITTER ACTUALLY WROTE, not on cpu_only.
     cpu_only is a property of the CYCLE (every proc is a CPU proc); the lane
     counts are a property of the BUILD, and they differ -- a CPU-only cycle
     still gets a GPU observer lane on a store-only shape.  Keying the build
     claim on the cycle property made the caveat assert "HET_GPU_LANES is 0" on
     two harnesses where it is 1 (MEASURED: 2+2W-cpuonly-x86_64,
     R-cpuonly-x86_64).  A harness that merely FORGOT to request a reachable
     mechanism still cannot borrow this excuse: a nonzero lane count no longer
     raises the flag for that mechanism, and het_dead() disqualifies it. */
  if (r->gpu_lanes == 0 || r->spin_lanes == 0)
                                    cv |= HET_CV_NO_GPU_LANES;
  { uint64_t spins = r->spin_rendezvous + r->spin_cap;
    if (spins && r->spin_rendezvous * 2 < spins) cv |= HET_CV_SPIN_CAP; }

  /* ---- 2. A SIGHTING, believed unconditionally: no control is needed to believe
     a positive, and an inert-stress run that saw the outcome still saw it.

     Counting the heuristic tally as well diverges from Q4 3.3, which keys the
     sighting off target_count_exhaustive alone: on a T_L>=2 shape at production N
     it is 0 by construction (HET_EXHAUSTIVE_MAX), so a real sighting would be
     silently dropped.  The windowed heuristic searches [c-W, c+W] against the
     ground-truth scan's [0, N-1] under the same predicate, so its hits are a
     subset -- it can miss cycles, it cannot invent them.  Flagged
     HET_CV_HEURISTIC_SIGHT so the report never passes it off as ground truth. */
  if (r->target_count_exhaustive > 0 || r->target_count_heuristic > 0) {
    if (r->target_count_exhaustive == 0) cv |= HET_CV_HEURISTIC_SIGHT;
    if (dq_out) *dq_out = 0;
    if (cv_out) *cv_out = cv;
    return HET_OBSERVED;
  }

  /* ---- 3. Liveness: is this run's null even a datum?  A null from an
     inert-stress run is not the same datum as one from a stressed run, and
     nothing else in the record would say so.
     Neither layer co-running => no liveness evidence of any kind, whatever the
     counters say.  True of exactly the two tests that ARE the canary. */
  if (!r->control_compiled_in && !r->canary_compiled_in)
                                                  dq |= HET_DQ_NO_CONTROL_BUILT;
  /* Channel-aware interleaving-liveness, mirroring het_cell_degenerate: the sync
     channel's evidence is interleavings_detected (a reader saw the two engines
     overlap), the observer channel's is observer_unique_count.  A store-only shape
     has no reader, so interleavings_detected is structurally 0 there and reading
     it would condemn every such cell forever.  The no-channel arm is unreachable
     in the shipped corpus and fails closed. */
  if (r->sync_valid) {
    if (r->interleavings_detected == 0)           dq |= HET_DQ_NO_INTERLEAVING;
  } else if (r->obs_valid) {
    if (r->observer_unique_count < (uint64_t)HET_THETA_DISTINCT)
                                                  dq |= HET_DQ_OBSERVER_COLD;
  } else                                          dq |= HET_DQ_NO_INTERLEAVING;
  if (r->stress_truncated > 0)                    dq |= HET_DQ_STRESS_TRUNCATED;
  /* The window-opener: requested via HET_BARRIER_PCT, evidenced by the spin
     tally.  Zero spins across an entire run means it never ran. */
  if (het_dead(req, HET_REQ_SPIN, r->spin_rendezvous + r->spin_cap))
                                                  dq |= HET_DQ_SPIN_DEAD;
  /* The GPU scratchpad stress, evidenced by het_stress.cuh's round tally
     (HET_TALLY_STRESS_ROUNDS).  This check and stresscheck.py are not redundant:
     this one proves the loop RAN, stresscheck.py proves it still CONTAINS its
     scratchpad accesses and that they survive the -D pattern knobs.  A layer can
     be in the source, gone from the PTX, and green on every structural gate. */
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

  /* ---- 5. The outcome.  NOT OBSERVED -- and what vouches for the harness that
     did not see it is the whole difference between the two null tiers. */
  if (dq) {
    v = HET_COLD_INVALID;
  } else if (hot_control && r->exhaustive_valid) {
    /* mu(T) fired on the same run, stress and C2C path, and T's own two engines
       provably overlapped: the harness produced a cross-device interleaving of
       T's own shape, and the zero is a ground-truth zero. */
    v = HET_NOT_OBSERVED_MU_HOT;
  } else {
    /* Either no mu co-runs or it did not reach tau_hot -- so only the canary
       vouches, and this SHAPE's window is unconfirmed -- or the ground-truth scan
       never ran, so the zero is not a measured zero.  het_verdict_print names
       which; both are reasons to escalate stress tuning rather than to report. */
    v = HET_NOT_OBSERVED_CANARY_ONLY;
  }

  if (dq_out) *dq_out = dq;
  if (cv_out) *cv_out = cv;
  return v;
}

static const char *het_verdict_name(het_verdict_t v) {
  switch (v) {
  case HET_OBSERVED:                  return "OBSERVED";
  case HET_NOT_OBSERVED_MU_HOT:       return "NOT-OBSERVED-MU-HOT";
  case HET_NOT_OBSERVED_CANARY_ONLY:  return "NOT-OBSERVED-CANARY-ONLY";
  default:                            return "COLD-INVALID";
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
    "HetObs %s cpu_only=%d "
    "inst=%d run=%d conf=%d report=%d N=%llu frames=%llu target=%s%llu/%llu "
    "interleavings=%llu distinct_iters=%llu ws_via_obs=%llu obs_unique=%llu "
    "skew=[%d,%d] mean=%.3f sd=%.3f ctrl=%s%llu/%llu canary=%s%llu/%llu Prep=%.6f built=%d/%d "
    "spin=%llu/%llu stress_trunc=%llu do_stress_rounds=%llu req=0x%x "
    "enemies=%u enemy_rounds=%llu enemy_acc=%llu preload=%llu "
    "noise_cpu=%llu/%lluw noise_gpu=%u/%u noise_ws=%uMB place=%u nwin=%u "
    "aff_fail=%u place_fail=%u\n",
    _r->test_name,
    _r->cpu_only,
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
 * The reporting contract (Q4 5): NEVER print a bare "Never".  Every null prints
 * paired with the control that vouches for it, in absolute numbers, so a reader
 * can recalibrate the bar instead of taking our word for it.  Where a shape's
 * control cannot be made hot we say so plainly (the printouts below carry
 * Alglave's GTX-280 precedent verbatim).
 * ------------------------------------------------------------------------- */
/* The stress-provenance caveats, printed for a sighting as well as for a null. */
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
    fprintf(_ch, "  CAVEAT: %s was REFUSED -- HET_PLACE placed nothing.\n",
            HET_PLACE_LEVER);
  if (cv & HET_CV_NO_GPU_LANES) {
    /* The two mechanisms are named SEPARATELY and only where the lane count says
       so, because they are withheld separately (hetEmit.ml's stress_requested
       expression guards HET_REQ_GPU_STRESS on HET_GPU_LANES and HET_REQ_SPIN on
       HET_SPIN_LANES).  The counts are printed so the claim is checkable against
       the harness's own #defines instead of being asserted. */
    fprintf(_ch,
      "  CAVEAT (D10): HET_GPU_LANES=%d HET_SPIN_LANES=%d on this harness.  A "
      "mechanism whose lane count is 0 is STRUCTURALLY ABSENT, not dead "
      "(het_do_stress's round loop is guarded by `_gpu_done < HET_GPU_LANES', "
      "which is false at 0 before the body runs once), so it is NOT counted as "
      "requested and its zero tally is not a disqualifier -- see stress_requested "
      "in the config line.  Absent here:%s%s.\n",
      _r->gpu_lanes, _r->spin_lanes,
      _r->gpu_lanes == 0 ? " the GPU scratchpad stress" : "",
      _r->spin_lanes == 0 ? (_r->gpu_lanes == 0
                             ? " and the device-scope window-opener"
                             : " the device-scope window-opener") : "");
    /* ...and, symmetrically, what IS present must not be excused by this caveat.
       A nonzero lane count means the mechanism CAN run, so it was requested and a
       zero tally there is a disqualifier like anywhere else. */
    if (_r->gpu_lanes > 0 || _r->spin_lanes > 0)
      fprintf(_ch,
        "  CAVEAT (D10, cont.): the OTHER mechanism is present (%s lane(s)) and IS "
        "counted as requested -- this caveat does not excuse a zero tally there.\n",
        _r->gpu_lanes > 0 ? "GPU stress" : "window-opener");
  }
}

/* The stress incantations, travelling with every reported outcome -- a result
   obtained under a config nobody recorded is not reproducible. */
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

/* Where the number came from: a MEASUREMENT caveat, which is why it is separate
   from het_print_caveats()'s stress-provenance lines.  Every outcome needs it --
   on a T_L>=2 shape at production N both a zero and a count come from the windowed
   search, and "we could not expose it" without "in the window we searched"
   overstates the effort. */
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

/* "We did not see it", in the only vocabulary this harness has: the outcome the
   test's condition names, and the effort behind the zero. */
static void het_print_notobserved(FILE *_ch, const het_obs_record *_r) {
  fprintf(_ch,
    "  %s: the weak outcome was NOT observed -- 0 / N=%llu frames (%llu examined); "
    "interleavings_detected=%llu.\n",
    _r->test_name, (unsigned long long)_r->N,
    (unsigned long long)_r->frames_examined,
    (unsigned long long)_r->interleavings_detected);
}

/* How hot the harness was -- printed under every null of every class, because a
   non-observation is worth exactly what the co-running controls say (Q4 5.2). */
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
      "same %s path.\n",
      _r->canary_name ? _r->canary_name : "(none)",
      (unsigned long long)_r->canary_target_count, (int)HET_TAU_HOT,
      HET_LINK_NAME);
  /* On a store-only shape the observer IS the liveness channel: with no reader,
     interleavings_detected is structurally 0 and, printed alone, would misread as
     "nothing raced". */
  if (_r->obs_valid && !_r->sync_valid)
    fprintf(_ch,
      "  the CPU observer resolved %llu distinct GPU store-value(s) across the "
      "window (this store-only shape has no reader, so the observer -- not "
      "interleavings_detected -- is its liveness channel).\n",
      (unsigned long long)_r->observer_unique_count);
  if (!_r->control_compiled_in && !_r->canary_compiled_in) {
    /* The two tests that ARE the canary are supposed to land here; anything else
       landing here is an emitter bug, and the two must not print one sentence. */
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

  fprintf(_ch, "HetVerdict %s [%s]%s run=%d: %s\n",
          _r->test_name, het_conf_name(_r->reporting),
          _r->cpu_only ? " CPU-ONLY" : "",
          _r->run_id, het_verdict_name(v));

  /* ---- 0. Unstamped record: every field below rec_magic is whatever memset
     left, so nothing here was measured.  Say only that. */
  if (dq & HET_DQ_REC_UNSTAMPED) {
    fprintf(_ch,
      "  *** THIS RECORD CARRIES NO STAMP (rec_magic != HET_REC_MAGIC) ***\n"
      "  The emitted driver did not stamp it, so every count, flag and liveness "
      "tally read here is a memset zero rather than a measurement, and a zeroed "
      "record is indistinguishable from a harness that ran and saw nothing.  This "
      "is a BUILD BUG, not a result.  Rebuild; do not report.\n");
    return;
  }

  /* ================== THE SIGHTING (believed unconditionally) ================= */
  if (v == HET_OBSERVED) {
    fprintf(_ch,
      "  ** %s: the weak outcome was OBSERVED %llu time(s) (exhaustive) / %llu "
      "(heuristic) in N=%llu frames (%.4f%%).\n"
      "  Report it as what %s exhibited under this harness, this stress and this "
      "%s path.  It is an OBSERVATION: this harness carries no prediction, so "
      "nothing here confirms or contradicts any model.  Comparing it against a "
      "verdicts file is an offline step (hetlitmus/oracle-compare.sh).\n",
      _r->test_name,
      (unsigned long long)_r->target_count_exhaustive,
      (unsigned long long)_r->target_count_heuristic, _n, _pct,
      HET_PAIR_NAME, HET_LINK_NAME);
    if (_r->cpu_only) {
      /* D10 (memo 7.D10) says WHAT WAS UNDER TEST, which is not a model call:
         every proc is a CPU proc, so no cross-device path carried this cycle and
         what fired is the host ISA on the shared allocation.  The x86 ordering
         rules are scoped to WB (write-back cacheable) memory ([APM] 7.2, [CACM]
         p.90) and a WC mapping legalises store-store and load-load reordering
         outright (memo sect 8 P1), so the MAPPING is part of what this row
         measures -- and a UC mapping reorders nothing at all ([APM] Table 7-2),
         which is why a sighting rules that one out. */
      fprintf(_ch,
        "  ** CPU-ONLY CYCLE (D10): every proc of this test is a CPU proc, so NO "
        "CROSS-DEVICE PATH CARRIED THIS CYCLE -- what fired is the host ISA on the "
        "SHARED ALLOCATION.  The memory TYPE of that allocation is part of what "
        "this row measures (WB vs WC, memo sect 8 P1); the sighting does rule out "
        "an uncacheable (UC) mapping, which reorders nothing ([APM] Table 7-2), "
        "but it does not by itself establish WB over WC.\n");
      /* The `co' edge of a store-only shape comes from an OBSERVER, and this
         harness carries two -- a CPU thread and a GPU lane.  Which one closed the
         cycle decides whether a host-ISA agent observed anything at all, so it is
         printed rather than assumed. */
      if (_r->obs_ws_via_gpu && !_r->obs_ws_via_cpu)
        fprintf(_ch,
          "  ** THE co EDGE CAME ONLY FROM THE GPU OBSERVER (obs_ws_via_gpu=1, "
          "obs_ws_via_cpu=0), AND THE GPU IS NOT AN x86 AGENT.  No x86 agent "
          "observed these two x86 stores out of order, so this is a "
          "cross-device-visibility observation about this platform and not a datum "
          "about the host ISA.  For the host ISA itself, run a shape with an x86 "
          "READER (MP / LB / SB / IRIW), whose cycle closes inside the CPU.\n");
      else if (_r->obs_ws_via_cpu)
        fprintf(_ch,
          "  ** The co edge WAS recovered by the x86-side observer "
          "(obs_ws_via_cpu=1), so the cycle closed inside the CPU domain.\n");
    }
    if (cv & HET_CV_HEURISTIC_SIGHT)
      fprintf(_ch,
        "  NOTE: this sighting came from the WINDOWED heuristic, so confirm it by "
        "re-running with -DHET_EXHAUSTIVE_MAX above N.\n");
    het_print_config(_ch, _r);
    het_print_scan_caveat(_ch, _r, cv);
    het_print_caveats(_ch, _r, cv);
    return;
  }

  /* ===================== NOT OBSERVED.  It NEVER prints alone. ================= */
  het_print_notobserved(_ch, _r);
  /* Covers all three sub-cases: mutant co-running, canary co-running, and neither
     -- where it further separates the tests that ARE the canary (designed) from a
     harness whose control silently went missing (a bug). */
  het_print_liveness(_ch, _r);

  if (v == HET_COLD_INVALID) {
    fprintf(_ch, "  DISCARD this null -- the harness was not demonstrably hot:\n");
    if (dq & HET_DQ_NO_CONTROL_BUILT)
      fprintf(_ch, "    - no positive control was compiled in (B6b)\n");
    if (dq & HET_DQ_NO_INTERLEAVING)
      fprintf(_ch, "    - interleavings_detected == 0: the two engines never "
                   "overlapped; nothing raced, so nothing could have been seen\n");
    if (dq & HET_DQ_OBSERVER_COLD)
      fprintf(_ch, "    - observer_unique_count=%llu < %d: the CPU observer "
                   "resolved fewer than two distinct GPU store-values, so the "
                   "store-only OBSERVER channel was COLD -- this shape has no "
                   "reader, the observer is its only liveness channel, and this "
                   "null is therefore not a datum\n",
              (unsigned long long)_r->observer_unique_count,
              (int)HET_THETA_DISTINCT);
    if (dq & HET_DQ_CONTROLS_COLD)
      fprintf(_ch, "    - neither mu(T) nor the canary reached tau_hot=%d: a "
                   "known-weak behaviour on this very machinery did not fire, so "
                   "this harness is not shown to expose anything\n",
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
      fprintf(_ch, "    - %s of the %s noise did NOT run: this run "
                   "is not interconnect-stressed\n",
              HET_HOST_HALF, HET_LINK_NAME);
    if (dq & HET_DQ_NOISE_GPU_DEAD)
      fprintf(_ch, "    - %s of the %s noise did NOT run: this run "
                   "is not interconnect-stressed\n",
              HET_DEV_HALF, HET_LINK_NAME);
    if (dq & HET_DQ_GPU_STRESS_DEAD) {
      fprintf(_ch, "    - the GPU scratchpad stress was requested "
                   "(HET_PRE_STRESS_PCT/HET_MEM_STRESS_PCT) but het_do_stress "
                   "completed ZERO rounds: it never ran\n");
      /* Alglave's "zero without stress" is an NVIDIA measurement and this
         project has already recorded it as NVIDIA-only (B4).  Printing it as a
         general fact on an AMD-tagged run would be borrowing somebody else's
         number; saying that no equivalent number exists is the honest form, and
         PORT2-reading-list.md is where that gap was established.  Keyed on an
         explicit stamp, never on the shape of a string: the emitter sets
         HET_ALGLAVE_ZERO_MEASURED for the machines the figure was measured on
         and for no others. */
      if (HET_ALGLAVE_ZERO_MEASURED)
        fprintf(_ch, "      On NVIDIA silicon an unstressed run observes nothing "
                     "(Alglave 4.3.1)\n");
      else
        fprintf(_ch, "      (Alglave 4.3.1's \"zero without stress\" was measured "
                     "on NVIDIA parts and is NOT claimed for this target; no "
                     "equivalent figure is published for it, so the dead "
                     "mechanism disqualifies this run on its own terms)\n");
    }
    het_print_caveats(_ch, _r, cv);
    return;
  }

  if (v == HET_NOT_OBSERVED_MU_HOT)
    fprintf(_ch,
      "  NOT OBSERVED, MU HOT: mu(T) -- a strictly weaker, structurally identical "
      "sibling of this test -- fired reproducibly on the same launch, stress and "
      "%s path, so the harness demonstrably produced a cross-device interleaving "
      "of THIS shape and the zero is a ground-truth zero.  Report it as \"not "
      "observed under this effort\", never as \"cannot happen\".\n",
      HET_LINK_NAME);

  if (v == HET_NOT_OBSERVED_CANARY_ONLY) {
    fprintf(_ch, "  NOT OBSERVED, CANARY ONLY -- reportable, but weaker than it "
                 "looks:\n");
    if (!_r->control_compiled_in)
      fprintf(_ch, "    - no mu(T) co-runs: the control map found no strictly "
                   "weaker sibling of this test, so nothing of its OWN shape "
                   "vouches for it and only the %s path is shown alive.\n",
              HET_LINK_NAME);
    else if (cv & HET_CV_CANARY_ONLY)
      fprintf(_ch, "    - only the Layer-B canary fired: the %s path is alive, "
                   "but this SHAPE's window was not demonstrably hit.  Escalate "
                   "stress tuning for it (B8).\n",
              HET_LINK_NAME);
    if (cv & HET_CV_NO_EXHAUSTIVE)
      fprintf(_ch, "    - the O(N^T_L) ground-truth scan did not run at N=%llu, so "
                   "this is NOT a measured zero (the CAVEAT below says why).\n",
              (unsigned long long)_r->N);
  }

  /* One sentence for both tiers, because it is the same statement: a null is a
     fact about this harness's reach, not about a model.  Alglave et al. said it
     first about their own null on the chip [19] reported weak behaviours on. */
  fprintf(_ch,
    "  Either way this is an OBSERVABILITY result about this harness on this "
    "hardware and under this stress -- never a model result -- and it feeds the "
    "stress-tuning priority (B8).  The precedent for saying so plainly:\n"
    "    \"In fairness to the authors of [19], we were unable to observe weak "
    "behaviours using our\n"
    "     method on the Nvidia GTX 280 chip they used.\"\n"
    "                                     -- Alglave et al., ASPLOS'15, fn.7, p.577.\n");
  if (_r->cpu_only)
    /* D10's null half: on a CPU-only shape the weak outcome is the host store
       buffer, among the most reproducible relaxations the ISA has, so a null is
       evidence about the ALLOCATION rather than about a narrow window. */
    fprintf(_ch,
      "  *** D10 / SHARED-ALLOCATION PROBE: this is a CPU-ONLY shape, and its weak "
      "outcome is the host STORE BUFFER -- among the most reproducible relaxations "
      "the ISA has.  A null here is evidence about the SHARED ALLOCATION, not a "
      "narrow window: if the mapping is not WB (write-back cacheable), memo sect 8 "
      "P1 is UNRESOLVED.  Check PAT/MTRR and /proc/self/smaps for this allocator "
      "before running anything else.\n");

  het_print_scan_caveat(_ch, _r, cv);
  het_print_caveats(_ch, _r, cv);
}

/* =========================================================================
 * THE STATISTICS LAYER -- what a "Never" is worth.  A pure function of an array
 * of het_obs_records (host-side post-pass, Q3 6.6), so it is unit-testable from
 * synthetic record streams: hetlitmus/verify/statscheck.py.
 *
 * The frame is not the trial: the scan validates N^{T_L} overlapping frames per N
 * iterations (PerpLE VI-B.1), so the replication unit is the (instance,run) cell,
 * Y = 1[target_count >= 1], and that Y is the n in every formula here.  Nor does
 * the rule of three survive the burstiness -- a bursty process parks more mass at
 * zero -- so the constant 3 is replaced by the negative-binomial zero-event bound
 * mu_upper(r) = r(0.05^{-1/r} - 1) with r_hat MEASURED from the control channel,
 * and where the dispersion cannot be measured no bound is printed at all: a
 * fallback to 3/N would be a ~6x overclaim on a channel with Fano ~20.
 *
 * Three strata, three instruments, never one number doing two corrections:
 *   F_win   Var/Mean of the per-window control counts -> r_hat -> mu_upper
 *   tau_w   autocorrelation time of the same stream   -> N_eff = HET_NWIN/tau_w
 *   F_cell  Var/Mean of the per-cell control totals   -> DEFF
 *   R_eff = R_usable * N_eff / max(1, F_cell)
 * Every clamp is one-directional, so the composition can only widen the bound;
 * one interaction is disclosed rather than removed (section 4b below).  The
 * stationarity precheck is Kirkham 4.3's, which already fails 4 of 18 chip/test
 * combinations GPU-only -- hence mandatory here -- with one divergence: they
 * KS-test a POISSON FIT of the early against the late window, we two-sample KS the
 * counts directly, the Poisson being the wrong likelihood by the finding above.
 * Derivation and sources: Q3-stats.md (2.4 the NB table, 3 the units, 4.2 the
 * strata); B7*-impl-brief.md.
 * ========================================================================= */

/* What the campaign SAW, at the (instance,run) unit. */
typedef enum {
  HET_OBS_VOID = 0,   /* not one usable cell: every run was COLD.  A bound computed
                         over these would be a bound on nothing. */
  HET_OBS_NEVER,      /* k = 0 usable cells observed it -> the false-negative bound */
  HET_OBS_SOMETIMES,
  HET_OBS_ALWAYS
} het_obs_class;

/* Corroboration.  A sighting that does not reproduce is the most damaging thing
   this campaign can write down, and Srivastava observed the mechanism that would
   forge one: a constant-read artefact (a reader stuck on init or on one value)
   yields a spurious 100%/0%.  The fix is not to suppress sightings --
   falsification is one-sided.  "Is the sighting real?" (decoder soundness) and
   "is it reproducible?" (statistical confidence) are two questions, so they get
   two answers: het_verdict() still returns HET_OBSERVED on the first sighting,
   and this tier layers on top and suppresses nothing.

   HET_CORROB_RUNS is the campaign's corroboration bar, and it is NOT Kirkham's
   n = 3: three clean runs are the 95% P_rep recipe (Q3 R2), while two are what
   rules out a per-run artefact at all.  The measured P_rep is printed beside the
   tier, so the bar and the confidence it bought are never conflated. */
#define HET_CORROB_RUNS 2
typedef enum {
  HET_SIGHT_NONE = 0,
  HET_SIGHT_UNCONFIRMED,   /* seen, but in fewer than HET_CORROB_RUNS clean RUNS,
                              or only in degenerate cells: believe it, report it,
                              and reproduce it before writing it up. */
  HET_SIGHT_CORROBORATED   /* >= HET_CORROB_RUNS distinct non-degenerate RUNS */
} het_sighting_tier;

/* Why a statistic is missing or weakened.  Each one is a way this layer could
   silently go constant, so each one is PRINTED. */
#define HET_ST_FANO_UNMEASURED   (1u << 0) /* control never fired: NO BOUND, and we
                                              do NOT substitute the textbook 3/N   */
#define HET_ST_NONSTATIONARY     (1u << 1) /* KS rejected: P_rep suppressed (Q3 R4) */
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
#define HET_ST_SELF_CONTROL     (1u << 11) /* co-runs no control AND names ITSELF
                                              the canary: usable == fired       */
#define HET_ST_TAU_UNMEASURED   (1u << 12) /* no usable stream for the IPS: N_eff
                                              stays 1, one trial per run -- the
                                              maximally conservative reading    */
#define HET_ST_TAU_AT_CAP       (1u << 13) /* tau_w clamped at HET_NWIN: the skew
                                              regime outlives the run at this
                                              resolution, so one run IS one
                                              alignment draw (N_eff = 1).  Sweep a
                                              finer HET_NWIN to probe it.       */
#define HET_ST_TAU_UNRESOLVED   (1u << 14) /* pooled stream shorter than
                                              HET_TAU_MIN_SAMPLES * tau_w, so tau
                                              buys nothing: N_eff = 1.  Not a veto
                                              but an actionable "run more runs" --
                                              the criterion is on the POOLED count
                                              R x HET_NWIN, so it relaxes on its
                                              own; tau_runs_needed prices it.   */
#define HET_ST_MIXED_POOL       (1u << 15) /* the cells pooled here do NOT all
                                              agree on cpu_only.  Cannot happen
                                              from one harness -- one binary, one
                                              test -- so it means records from
                                              different builds were pooled.
                                              Resolved toward the WEAKER claim
                                              about the compound model (cpu_only
                                              wins), never away from it.       */
#define HET_ST_NO_CONTROL_CORUN (1u << 16) /* co-runs no control and does NOT name
                                              itself the canary.  Same selection
                                              effect (usable == fired), a
                                              different reason: no control map
                                              was read (HET_NO_CONTROL_MAP), or
                                              -- if one was -- the emitter built
                                              a harness that vouches for nothing.
                                              Which of the two is PRINTED.    */

typedef struct het_stats {
  const char *test_name;
  int cpu_only;
  het_obs_class obs;
  het_sighting_tier tier;

  int R;              /* cells supplied  (= NUMBER_OF_RUN; H is 1 today)          */
  int R_usable;       /* cells whose het_verdict() is not COLD-INVALID            */
  int k;              /* cells with Y = 1[target_count >= 1]                      */
  int k_eff;          /* ... of those, the ones that pass the decode guard        */
  int k_runs;         /* distinct RUNS among them (the most independent draws)    */
  int n_degen;        /* sightings REJECTED by the guard (reported, never hidden) */
  /* Distinct runs consumed when the FIRST clean sighting landed; 0 = none did.
     The price of the sighting, in the unit the campaign spends (Q3 F4), and the
     one number a stop rule that watches for a lone sighting needs. */
  int n_at_first_sight;
  /* What the two control channels totalled over the cells pooled here, reported
     rather than left to be inferred from ctrl= and the per-run lines: which
     channel calibrated the dispersion is a flag, but HOW HOT each layer was is a
     number, and a campaign roll-up needs it machine-readably. */
  uint64_t mu_total, can_total;

  int    win_samples;               /* (run,window) samples behind F_win          */
  double ctrl_mean, ctrl_var;       /* of the per-window control counts           */
  double F_win, F_cell;             /* the two strata                             */
  double r_hat;                     /* NB dispersion from F_win (inf = Poisson)   */
  double mu_upper;                  /* r(0.05^{-1/r} - 1)                         */
  double tau_w;                     /* integrated autocorrelation time, WINDOW
                                       units (Geyer IPS); -1 = NOT MEASURED       */
  double N_eff;                     /* effective independent samples PER RUN =
                                       HET_NWIN/tau_w, clamped to [1, HET_NWIN];
                                       1 when tau is unmeasured or unresolved     */
  int    tau_runs_needed;           /* usable runs the aggregate needs for tau_w
                                       to clear HET_TAU_MIN_SAMPLES; 0 when tau
                                       was never measured.  Quoted whether or not
                                       it has been paid, so the invariant is
                                       exact: TAU_UNRESOLVED <=> R_usable < this  */
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
   of an NB(mu, r) process observed ZERO times.  Written with expm1 because the
   naive form cancels catastrophically as r grows, and the r -> inf limit IS the
   textbook rule of three -- getting it wrong there would silently reproduce the
   constant this function exists to replace.  0.05^{-1/r} = exp(ln(20)/r). */
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

/* Fano = Var/Mean of a sample.  Returns -1 when it CANNOT be measured (fewer than
   2 samples, or an all-zero stream): the caller must then print no bound, never a
   default -- an F_hat that silently falls back to 1 reports the textbook rule of
   three while claiming to be dispersion-aware. */
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
 * The integrated autocorrelation time, which lets a correlated stream be
 * DISCOUNTED rather than discarded: N_eff = N/tau, tau = 1 + 2*sum_k rho_k -- the
 * design-effect logic Q3 2.3 applies across cells, applied within the run (Q3 4.2,
 * open question 2).  Estimated from the control's per-window stream by Geyer's
 * initial-positive-sequence estimator (Geyer, "Practical Markov Chain Monte
 * Carlo", Statistical Science 7(4), 1992, 3.3: sum the adjacent-pair sums
 * Gamma_m = rho_{2m} + rho_{2m+1} while they stay positive), which reads the whole
 * initial decay -- unlike 1/(1-acf1), which a slowly-decaying ACF makes
 * arbitrarily optimistic.  On AR(1) it recovers tau = (1+rho)/(1-rho) in
 * expectation, which is what statscheck.py pins it against.
 *
 * Mechanics: lags are taken WITHIN runs and pooled (a lag across a re-seeded run
 * boundary is not a lag), deviations from the global mean, so an across-run rate
 * difference inflates tau -- toward N_eff = 1, the conservative direction;
 * autocovariances use the biased 1/n normalisation, standard for an IACT; the
 * result is clamped to [1, wlen], because an anti-correlated stream cannot yield
 * more samples than it has windows and an unresolvable correlation must saturate
 * at "one run = one draw" rather than extrapolate.  Returns -1 when tau cannot be
 * measured at all (short stream, <2 windows/run, zero variance); the caller then
 * keeps N_eff = 1. */
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

/* The price of the claim.  The reliability criterion is on the POOLED sample count
   (nwin = usable runs x HET_NWIN), so an unresolved tau is not a dead end but a
   price: this returns how many usable runs the aggregate needs for tau_w to clear
   HET_TAU_MIN_SAMPLES * tau_w samples.  At HET_NWIN = 128, R = 10 pools 1,280 and
   resolves tau <= 25.6; R = 100 pools 12,800 and resolves tau <= 256.  Grow R, not
   N (Q3 F4): extra iterations add correlated frames inside the same alignment
   windows, a fresh run adds a fresh phase/seed/thermal draw.  (A finer HET_NWIN
   also raises the pooled count but trades against resolution, so R is the clean
   lever.)  0 = nothing to buy: tau resolved, or never measured. */
static int het_tau_runs_needed(double tau_w) {
  double need;
  if (!(tau_w > 0.0)) return 0;                     /* unmeasured: no price to quote */
  need = HET_TAU_MIN_SAMPLES * tau_w / (double)HET_NWIN;
  return (int)need + (((double)(int)need < need) ? 1 : 0);   /* ceil */
}

/* How long to run before a "Never" means anything: Kirkham's necessary-iteration
   inverse N = log(1-P_rep)/log(1-p) (1.1 p.226:4), fed with run-level rates and
   inflated by the measured dispersion,

       R  >=  F_hat * log(0.05) / log(1 - p_min)

   i.e. enough near-independent cells that a target as rare as p_min would have had
   a 95% chance to show up.  Returns -1 when p_min is unset, which it is (HET_P_MIN):
   any number here would be imported from a different experiment, and a budget
   invented from the wrong experiment is worse than none because it looks like one. */
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
   (ties depress D) and so under-rejects: a pass here is the weaker of the two
   claims, a split the stronger. */
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

/* The decode guard: is this cell's decode trustworthy, or could the "sighting" be
   Srivastava's constant-read artefact?  A ZERO FIELD IS NOT A DEGENERATE DECODE --
   a store-only shape has no reader (so it cannot have a constant-read artefact at
   all) and leaves the synchrony fields at their memset zero, decoding through the
   observer instead.  Every test has one channel or both, so the guard switches
   channel instead of firing blind.  The no-channel arm is unreachable in the
   shipped corpus and fails closed anyway: a sighting nothing can vouch for must not
   count toward corroboration. */
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
  int    allruns[HET_STATS_MAX_CELLS];
  int i, w, nwin = 0, ne = 0, nl = 0, ncell = 0, nruns = 0, nall = 0, use_canary;
  int n_early, n_late, ks;
  uint64_t mu_total = 0;
  int mu_present = 0;

  memset(st, 0, sizeof *st);
  st->p_bound = -1.0;                 /* -1 = NOT COMPUTED.  Never a silent 3/N. */
  st->P_rep   = -1.0;                 /* -1 = NOT APPLICABLE                     */
  st->F_win   = -1.0;
  st->F_cell  = -1.0;
  st->r_hat   = HUGE_VAL;
  st->tau_w   = -1.0;                 /* -1 = NOT MEASURED                       */
  st->N_eff   = 1.0;                  /* one trial per run until a MEASURED tau
                                         says otherwise: the default is the
                                         conservative case, so an unmeasured
                                         stream can never buy a tighter bound. */
  st->ks_split_window = -1;
  if (n <= 0) { st->obs = HET_OBS_VOID; st->flags |= HET_ST_FANO_UNMEASURED; return; }
  st->test_name = recs[0].test_name;
  st->N         = recs[0].N;
  st->R         = n;
  /* Whether this is a D10 cycle -- a CHECK rather than an assumption: if the cells
     handed here do not agree on cpu_only they are not one campaign. */
  st->cpu_only      = recs[0].cpu_only;
  { int _i;
    for (_i = 1; _i < n; _i++)
      if (recs[_i].cpu_only != recs[0].cpu_only) {
        st->flags |= HET_ST_MIXED_POOL;
        /* cpu_only resolves upward, because it names the NARROWER experiment: a
           CPU-only cycle crossed no device boundary, so pooling it with het cells
           must not let the het reading absorb it silently. */
        if (recs[_i].cpu_only) st->cpu_only = 1;
      }
  }
  if (n > HET_STATS_MAX_CELLS) { n = HET_STATS_MAX_CELLS;
                                 st->flags |= HET_ST_CELLS_TRUNCATED; }

  /* ---- 1. Which control channel calibrates the dispersion.  mu(T) is the
     shape-matched proxy, so it is preferred where it exists and fired; the canary
     is the universal floor and is all a test at the lattice floor has.  A bound
     calibrated off another shape's burstiness is a weaker claim, so which one was
     used is recorded and printed rather than left to the reader to guess. */
  for (i = 0; i < n; i++) {
    if (recs[i].control_compiled_in) mu_present = 1;
    mu_total     += recs[i].control_target_count;
    st->can_total += recs[i].canary_target_count;
  }
  st->mu_total = mu_total;
  use_canary = (mu_present && mu_total > 0) ? 0 : 1;
  if (use_canary) st->flags |= HET_ST_CTRL_IS_CANARY;

  /* ---- 2. The cells.  het_verdict() is already a pure function of the record, so
     the aggregate reuses it rather than re-deriving liveness -- inheriting every
     stress disqualifier for free. */
  for (i = 0; i < n; i++) {
    uint32_t dq = 0, cv = 0;
    het_verdict_t v = het_verdict(&recs[i], &dq, &cv);
    /* An UNSTAMPED cell is read by nothing here either: het_verdict() stops at
       rec_magic, so every count below it -- the target tallies a sighting would be
       scored from included -- is whatever memset left.  Without this the aggregate
       would let a harness the emitter built wrong corroborate itself and stop. */
    int stamped = !(dq & HET_DQ_REC_UNSTAMPED);
    int y   = stamped && (het_reported_count(&recs[i]) >= 1);
    int deg = het_cell_degenerate(&recs[i]);
    uint64_t tot = het_ctrl_total(&recs[i], use_canary);
    uint64_t sum = 0;

    /* A SIGHTING is never COLD (het_verdict believes a positive unconditionally),
       so a usable-cell count can never discard one. */
    if (v != HET_COLD_INVALID) st->R_usable++;

    if (!recs[i].sync_valid && !recs[i].obs_valid)
      st->flags |= HET_ST_NO_DECODE_CHANNEL;

    /* Runs consumed so far, counted over EVERY cell and not only the sighting
       ones: n_at_first_sight is a price in runs, so the denominator is the runs
       that were actually spent. */
    { int j, seen = 0;
      for (j = 0; j < nall; j++) if (allruns[j] == recs[i].run_id) seen = 1;
      if (!seen) allruns[nall++] = recs[i].run_id; }

    if (y) {
      st->k++;
      if (deg) { st->n_degen++; st->flags |= HET_ST_DEGEN_SIGHTING; }
      else {
        int j, seen = 0;
        st->k_eff++;
        for (j = 0; j < nruns; j++) if (runs[j] == recs[i].run_id) seen = 1;
        if (!seen) runs[nruns++] = recs[i].run_id;
        if (st->n_at_first_sight == 0) st->n_at_first_sight = nall;
      }
    }

    /* The self-proving invariant: the window bump sits on the same line, under the
       same predicate, as the total, so these must agree.  If they do not, the
       sub-tallies are dead or mis-indexed and every dispersion number below is
       fiction.  This is the one check that catches a dead-code-eliminated tally on
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

  /* ---- 3. The observation class at the (instance,run) unit (Q3 R1).
     THE SELECTION EFFECT: a cell is usable if it fired or if its control was hot,
     so where nothing co-runs "usable" is defined by firing -- the survivors are
     tautologically the runs that fired, and classifying over them reports ALWAYS
     for a row that fired in 3 runs of 10.  The denominator is therefore R, the
     runs executed, for BOTH rows that co-run nothing; only the reason differs,
     and the two must not be conflated because only one of them is a canary.
     A row is the Layer-B canary when it NAMES ITSELF one, which is the same test
     the per-run liveness block makes; a row that co-runs nothing without naming
     itself has no control map behind it (or an emitter that built it wrong). */
  { int denom;
    for (i = 0; i < n; i++)
      if (recs[i].control_compiled_in || recs[i].canary_compiled_in) break;
    if (i == n) {
      if (recs[0].canary_name && recs[0].test_name
          && strcmp(recs[0].canary_name, recs[0].test_name) == 0)
        st->flags |= HET_ST_SELF_CONTROL;
      else
        st->flags |= HET_ST_NO_CONTROL_CORUN;
    }
    denom = (st->flags & (HET_ST_SELF_CONTROL | HET_ST_NO_CONTROL_CORUN))
            ? st->R : st->R_usable;
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

  /* ---- 4b. The third stratum: the TEMPORAL axis of the same per-window stream.
     F_win prices within-window burst multiplicity (widening the numerator,
     mu_upper), tau_w prices window-to-window correlation (discounting the
     denominator's sample count), F_cell prices the across-cell spread -- three
     questions, three measurements, since one number doing two corrections would
     double-count itself.  One interaction is disclosed rather than removed: F_cell
     is measured on run TOTALS, which a within-run correlation also inflates
     (E[F_cell] ~ tau_w * F_win for a stationary stream), so composing N_eff with
     F_cell can price part of the correlation twice.  Both corrections point the
     same way -- wider -- so the composition is conservative, never optimistic.
     Measured only where the dispersion itself was. */
  if (st->flags & HET_ST_FANO_UNMEASURED) {
    st->flags |= HET_ST_TAU_UNMEASURED;
  } else {
    st->tau_w = het_tau_ips(win, nwin, HET_NWIN, st->ctrl_mean);
    st->tau_runs_needed = het_tau_runs_needed(st->tau_w);
    if (st->tau_w > 0.0) {
      /* Is tau itself RESOLVED?  The clamps below are one-directional but the
         estimator is not: on a stream too short for its own tau, Geyer IPS meets a
         spurious non-positive pair early, truncates, and returns a tau far below
         both the truth and the HET_NWIN ceiling -- so TAU_AT_CAP never fires and
         the under-read tau over-credits N_eff, tightening the bound past the truth.
         A series must be ~HET_TAU_MIN_SAMPLES times longer than the tau it claims
         to measure (grounding and its known-open limit: see HET_TAU_MIN_SAMPLES).
         nwin is the POOLED count across usable runs, so this self-relaxes as the
         campaign grows: a price, not a veto (het_tau_runs_needed). */
      if ((double)nwin < HET_TAU_MIN_SAMPLES * st->tau_w) {
        st->flags |= HET_ST_TAU_UNRESOLVED;
        st->N_eff  = 1.0;                    /* one trial per run, kept intact */
      } else {
        if (st->tau_w >= (double)HET_NWIN) st->flags |= HET_ST_TAU_AT_CAP;
        st->N_eff = (double)HET_NWIN / st->tau_w;
        /* The clamp is the honesty: a stream of HET_NWIN windows cannot witness
           more than HET_NWIN independent samples, nor fewer than 1. */
        if (st->N_eff < 1.0)               st->N_eff = 1.0;
        if (st->N_eff > (double)HET_NWIN)  st->N_eff = (double)HET_NWIN;
      }
    } else {
      st->flags |= HET_ST_TAU_UNMEASURED;   /* N_eff stays 1 */
    }
  }

  /* lag-1 autocorrelation, WITHIN runs (a lag across a re-seeded run boundary is
     not a lag).  DIAGNOSTIC ONLY: what enters the bound is the integrated time
     tau_w (section 4b), since a slowly-decaying ACF has a tau far larger than
     1/(1-acf1) suggests.  acf1 survives as the one-number burstiness explainer and
     as a cross-check on tau_w's direction. */
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

  /* ---- 5. The stationarity gate (Q3 R4-i; MANDATORY, not optional).  Kirkham's
     first-20%-vs-last-10% split moved to the window axis: early windows from every
     usable run against late windows from every usable run -- the axis on which
     warm-up, thermal/DVFS drift and alignment drift all act. */
  n_early = (HET_NWIN * 20) / 100; if (n_early < 1) n_early = 1;
  n_late  = (HET_NWIN * 10) / 100; if (n_late  < 1) n_late  = 1;
  for (i = 0; i + HET_NWIN <= nwin; i += HET_NWIN) {
    for (w = 0; w < n_early; w++)          early[ne++] = win[i + w];
    for (w = HET_NWIN - n_late; w < HET_NWIN; w++) late[nl++] = win[i + w];
  }
  st->ks_n_early = ne; st->ks_n_late = nl;
  /* A KS on an all-zero stream passes for free.  The `self' canary rows co-run no
     control by construction, so their control stream is structurally empty, as is
     that of any harness whose control never fired: D would be 0 against 0, the gate
     would report `pass', and P_rep would be unlocked by a test that never ran.
     Stationarity that CANNOT be tested must not be reported as tested. */
  ks = (st->flags & HET_ST_FANO_UNMEASURED)
       ? -1
       : het_ks2(early, ne, late, nl, &st->ks_D, &st->ks_Dcrit);
  if (ks < 0) {
    /* Cannot test => cannot claim.  Fail closed: ks_pass stays 0, so P_rep is
       suppressed below exactly as on a rejection. */
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

  /* ---- 6. OBSERVED (Q3 R2): P_rep at the (instance,run) unit, from k_eff, never
     from the frame count; suppressed across a non-stationary boundary (R4).
     The k_eff > 0 test is LOAD-BEARING, not a division guard: at k_eff = 0 -- every
     sighting rejected by the decode guard -- the formula returns 1 - e^0 = 0, and
     "P_rep = 0.00%" reads as "never reproduces" when what happened is that there is
     no clean cell to estimate from.  No estimate, so none is reported. */
  if (st->obs == HET_OBS_SOMETIMES || st->obs == HET_OBS_ALWAYS)
    if (st->ks_pass && st->k_eff > 0)
      st->P_rep = 1.0 - exp(-(double)st->k_eff);

  /* ---- 7. UNOBSERVED (Q3 R3): the dispersion-aware false-negative bound.  NOT
     COMPUTED, and emphatically not replaced by 3/N, when the dispersion could not
     be measured.  R_eff = R_usable * N_eff / DEFF, so each usable run contributes
     its measured effective sample count instead of the worst-case 1, and p_bound's
     unit is one tau_w-window alignment epoch rather than one run.  THE RUN-LEVEL
     IDENTITY: N_eff * p_bound = mu_upper * DEFF / R_usable, invariant to whatever
     N_eff is credited -- the discount adds resolution beneath the run-level claim
     and never tightens it, and at N_eff = 1 the two coincide. */
  if (st->obs == HET_OBS_NEVER && !(st->flags & HET_ST_FANO_UNMEASURED)) {
    double deff = (st->F_cell > 1.0) ? st->F_cell : 1.0;
    st->R_eff    = (double)st->R_usable * st->N_eff / deff;
    st->mu_upper = het_mu_upper(st->r_hat);
    if (st->R_eff > 0.0) st->p_bound = st->mu_upper / st->R_eff;
    /* A BOUND ABOVE 1 IS NOT A BOUND: the bounded rate is a probability, so
       "p < 6e10" is the absence of a claim, and printing it as a number invites it
       into a table as though it meant something.  It is what a heavily bursty
       channel does to a null -- so much mass parked at zero that seeing zero tells
       you almost nothing -- and that is itself the finding. */
    if (st->p_bound >= 1.0) st->flags |= HET_ST_BOUND_VACUOUS;
  }

  /* ---- 8. The corroboration tier, layered ON TOP of het_verdict()'s immediate
     HET_OBSERVED and never suppressing one.  Distinct RUNS, not merely distinct
     cells: runs are re-seeded and carry a fresh phase/thermal draw, so they are
     the most independent replicates the harness produces (Q3 3.1, F4). */
  if (st->k > 0)
    st->tier = (st->k_runs >= HET_CORROB_RUNS) ? HET_SIGHT_CORROBORATED
                                               : HET_SIGHT_UNCONFIRMED;
}

static const char *het_obs_class_name(het_obs_class c) {
  switch (c) {
  case HET_OBS_NEVER:     return "Never";
  case HET_OBS_SOMETIMES: return "Sometimes";
  case HET_OBS_ALWAYS:    return "Always";
  default:                return "VOID";
  }
}

static const char *het_sighting_name(het_sighting_tier t) {
  switch (t) {
  case HET_SIGHT_CORROBORATED: return "CORROBORATED";
  case HET_SIGHT_UNCONFIRMED:  return "UNCONFIRMED";
  default:                     return "none";
  }
}

/* The machine-readable line.  hetlitmus/oracle-compare.sh parses THIS and layers
   the annotation onto its offline comparison table (Q3 R6: augment, do not
   replace); hetlitmus/campaign.py schedules from it.  mu_total/can_total are here
   because a roll-up must be able to see HOW HOT each control layer was without
   re-reading the per-run lines. */
static void het_stats_line(FILE *_ch, const het_stats_t *_s) {
  fprintf(_ch,
    "HetStats %s cpu_only=%d obs=%s "
    "R=%d usable=%d k=%d k_eff=%d k_runs=%d degen=%d first_sight=%d "
    "ctrl=%s mu_total=%llu can_total=%llu "
    "win_n=%d nwin=%d F_win=%.4f F_cell=%.4f r_hat=%.4f mu_upper=%.4f "
    "tau_w=%.4f N_eff=%.4f tau_need=%d R_eff=%.4f "
    "p_bound=%.6g P_rep=%.6g acf1=%.4f ks=%s ks_D=%.4f ks_Dcrit=%.4f ks_split=%d "
    "sighting=%s N=%llu frames=%llu flags=0x%x\n",
    _s->test_name ? _s->test_name : "(none)",
    _s->cpu_only,
    het_obs_class_name(_s->obs), _s->R, _s->R_usable, _s->k, _s->k_eff, _s->k_runs,
    _s->n_degen, _s->n_at_first_sight,
    (_s->flags & HET_ST_CTRL_IS_CANARY) ? "canary" : "mu(T)",
    (unsigned long long)_s->mu_total, (unsigned long long)_s->can_total,
    _s->win_samples, (int)HET_NWIN, _s->F_win, _s->F_cell,
    (_s->r_hat >= HET_R_POISSON) ? INFINITY : _s->r_hat,
    _s->mu_upper, _s->tau_w, _s->N_eff, _s->tau_runs_needed,
    _s->R_eff, _s->p_bound, _s->P_rep, _s->acf1,
    (_s->flags & HET_ST_KS_UNDERPOWERED) ? "underpowered"
      : (_s->ks_pass ? "pass" : "SPLIT"),
    _s->ks_D, _s->ks_Dcrit, _s->ks_split_window,
    het_sighting_name(_s->tier),
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
                 "so they are treated as DEGENERATE.  This is a BUILD BUG (no emitted "
                 "harness should reach it).\n");

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
              ? "this harness has no live control stream to test (either nothing "
                "co-runs at all, or what does co-run never fired)"
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
    fprintf(_ch, "  CHARACTERIZATION, NEVER VALIDATION: the bound describes THIS "
                 "HARNESS's reach on this hardware under this stress.  This "
                 "harness carries no prediction, so the bound bears on no model "
                 "claim (Q4 R5); it feeds B8's stress-tuning priority.\n");
    fprintf(_ch, "  effort: %d run(s) x N=%llu iterations, %llu frames examined.\n",
            _s->R_usable, (unsigned long long)_s->N,
            (unsigned long long)_s->frames_examined);

    /* Was the effort ever SIZED?  A null is only meaningful against a budget, and
       an unsized null is not a wrong result but an unquantified one. */
    { double need = het_budget_runs((double)HET_P_MIN, _s->F_win);
      /* The budget is in EFFECTIVE CELLS: p_min is a per-effective-sample rate at
         a given HET_NWIN (measured at another window size it is a different
         number), and each usable run supplies N_eff of them, so the RUN budget is
         need/N_eff -- N_eff-fold fewer runs for the same claim. */
      if (need < 0.0)
        /* TARGET-AGNOSTIC BY CONSTRUCTION, and it has to be SAID so: every number
           this layer computes is a function of the record counts and of HET_NWIN /
           HET_TAU_HOT / HET_R_POISSON / HET_TAU_MIN_SAMPLES, none of them a vendor
           constant, so the arithmetic transfers unchanged and only the SENTENCE
           has to name a machine.  It names the pair the binary was built for.  The
           Bagchi disclaimer stays because on the AMD lane it is stronger, not
           weaker: no AMD heterogeneous litmus-testing prior work exists at all
           (PORT2-reading-list.md), so there is not even a GPU-only number to
           be tempted by.  hetlitmus/verify/verdictcheck.py phase 4 reads this
           sentence to check the harness names its OWN pair. */
        fprintf(_ch,
          "  budget: NOT SIZED.  p_min -- the per-effective-sample rate of the "
          "hardest het behaviour we can actually observe -- is HARDWARE-ONLY and "
          "unset (HET_P_MIN).\n"
          "          It is NOT Bagchi's ~0.2%%: that is the GPU-only INTER-CTA rate "
          "(their 5.1/4.1), which fires with no CPU participation and never crosses "
          "the interconnect.  There is no published numeric het hit-rate for ANY "
          "target, and none whatsoever for AMD.\n"
          "          Derive it ON THE MACHINE THIS BINARY WAS BUILT FOR -- the pair "
          "%s -- from the rows that DID exhibit their outcome (they ARE the "
          "observed-rate population, at THIS HET_NWIN) and re-run with "
          "-DHET_P_MIN=<rate>.  A p_min carried over from another target is not a "
          "conservative default, it is a different machine's number.\n",
          HET_PAIR_NAME);
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

  /* ---- observed.  The denominator is R wherever nothing co-runs and R_usable for
     everything else -- see the selection effect in het_stats_compute. */
  { unsigned nocorun = _s->flags & (HET_ST_SELF_CONTROL | HET_ST_NO_CONTROL_CORUN);
    int denom = nocorun ? _s->R : _s->R_usable;
    const char *unit = nocorun ? "run" : "usable cell";
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
        "  NOTE: this row CO-RUNS NO CONTROL -- it IS the Layer-B canary (the control "
        "map names it as its own canary), and a test cannot control itself (B6b).  A "
        "run in which it did not fire is therefore COLD and carries no information, so\n"
        "  \"usable cells\" is DEFINED BY firing.  The denominator above is R -- the "
        "runs executed -- not the usable count: otherwise a canary that fired in %d of "
        "%d runs would report ALWAYS, and that rate is precisely what the rest of the\n"
        "  campaign is calibrated against.  For the same reason this row has no "
        "independent channel to measure dispersion or stationarity against, so it gets "
        "NO BOUND -- by construction, not by omission.\n",
        _s->k, _s->R);
    else if (_s->flags & HET_ST_NO_CONTROL_CORUN) {
      /* The same arithmetic, and it must NOT borrow the sentence above: this row
         is not a canary, nothing here says it is one, and its missing bound is an
         omission we have not closed yet.  Saying otherwise would report a gap in
         the instrumentation as a property of the experiment. */
      if (HET_NO_CONTROL_MAP)
        fprintf(_ch,
          "  NOTE: this row CO-RUNS NO CONTROL because NO POSITIVE-CONTROL MAP WAS "
          "READ for %s -- no map is registered for that pair, and a map derived on "
          "another pair's strength lattice names siblings that are not weakenings\n"
          "  here, so there is none to borrow.  Nothing marks this row a canary.  A "
          "run in which "
          "it did not fire is COLD and carries no information, so \"usable cells\" is "
          "defined by firing and the denominator above is R -- the runs executed --\n"
          "  not the usable count, which would report ALWAYS for a row that fired in %d "
          "of %d runs.  It gets NO BOUND, and that is an OMISSION, not a construction: "
          "the bootstrap control map for an unregistered pair does not exist yet.\n",
          HET_PAIR_NAME, _s->k, _s->R);
      else
        fprintf(_ch,
          "  *** NOTE: this row CO-RUNS NO CONTROL, names no canary, and a control map "
          "WAS read for %s.  Nothing in this harness vouches for it and nothing says "
          "why -- that is a BUILD BUG, not a result.  The denominator above is R (%d "
          "of %d runs fired); no bound is reported.\n",
          HET_PAIR_NAME, _s->k, _s->R);
    }
  }

  if (_s->flags & HET_ST_DEGEN_SIGHTING)
    fprintf(_ch,
      "  *** %d SIGHTING(S) CAME FROM A DEGENERATE CELL *** (distinct_decoded_iters "
      "< %d, or a decode that never varied).  Srivastava observed exactly this "
      "artefact -- a reader stuck on init or on one value yields a spurious "
      "100%%/0%%.\n"
      "  They are REPORTED, not discarded: falsification is one-sided and a genuine "
      "sighting stands.  They just do not COUNT toward corroboration.\n",
      _s->n_degen, (int)HET_THETA_DISTINCT);

  /* THE SIGHTING TIER: how many independent runs reproduced it, and nothing else.
     Whether the outcome should have been seen is not a question this harness
     answers -- the comparison is offline (hetlitmus/oracle-compare.sh). */
  if (_s->tier != HET_SIGHT_NONE) {
    if (_s->tier == HET_SIGHT_CORROBORATED)
      /* The reproducibility clause follows the number: P_rep is suppressed
         whenever the stationarity gate did not pass or no cell survived the
         decode guard, and a tier that quotes a number the block above refused to
         report is quoting a -1. */
      fprintf(_ch,
        "  ** SIGHTING %s ** -- the weak outcome was observed in %d distinct "
        "non-degenerate RUN(S) (>= HET_CORROB_RUNS = %d).  A decoder artefact does "
        "not reproduce across re-seeded runs, so the SIGHTING IS REAL and not a "
        "constant-read.  %s\n",
        het_sighting_name(_s->tier), _s->k_runs, (int)HET_CORROB_RUNS,
        (_s->P_rep >= 0.0)
          ? "Its reproducibility is the P_rep above, MEASURED -- Kirkham's n = 3 "
            "=> 95% recipe is the bar for that number, not this one."
          : "HOW OFTEN it reproduces is NOT reported: P_rep is suppressed above, "
            "so this tier is a count of clean runs and nothing more.");
    else
      fprintf(_ch,
        "  ** SIGHTING %s ** -- the weak outcome was observed, but in only %d clean "
        "run(s) (< HET_CORROB_RUNS = %d).  BELIEVE IT AND REPORT IT: falsification "
        "is one-sided, so one sighting stands on its own and is NOT suppressed.  But "
        "a sighting that does not reproduce is the most damaging thing this campaign "
        "can write down, so REPRODUCE IT before it is written up.\n",
        het_sighting_name(_s->tier), _s->k_runs, (int)HET_CORROB_RUNS);
    if (_s->n_at_first_sight > 0)
      fprintf(_ch,
        "  It first fired after %d run(s) of the %d supplied, which is what a fresh "
        "campaign should budget for it (Q3 F4: grow R, not N).\n",
        _s->n_at_first_sight, _s->R);
    if (_s->cpu_only)
      fprintf(_ch,
        "  ** CPU-ONLY CYCLE (D10): every proc of this test is a CPU proc, so no "
        "cross-device path carried this cycle -- what fired is the host ISA on the "
        "shared allocation, and the memory type of that allocation is part of what "
        "it measures (memo sect 8 P1).\n");
  }
}

/* =========================================================================
 * THE CAMPAIGN STOPPING RULE -- where the hardware hours are saved.  ONE rule for
 * every test, because no test carries a prediction to schedule against: a row
 * stops once its sighting is CORROBORATED (nothing more is bought by running a
 * reproduced sighting further), and a row that never fires stops once its bound
 * is met or its budget is spent.  Most nulls converge early and only the stubborn
 * shapes need the long tail (Kirkham 4.2 ranks SB hardest on every chip).
 *
 * A LONE sighting does NOT stop the row: one clean run cannot rule out a per-run
 * artefact, so the row keeps running to corroborate -- to budget, today.  The
 * confirmation window that bounds that wait, and the rate mode that disables the
 * sighting stop, are not here yet.
 *
 * A pure function of the record stream, like het_verdict() and
 * het_stats_compute(), so the in-binary adaptive loop (HET_ADAPTIVE=1) and
 * hetlitmus/campaign.py's cross-invocation loop apply the SAME policy and
 * statscheck.py can unit-test it from synthetic records.
 *
 * Stopping on a bound is not data-peeking in the Kirkham 5.1 sense: p_bound is
 * computed only over all-zero records and only shrinks as zero-runs accumulate,
 * so the bound it stops at holds at that sample size.  (Kirkham's caution is
 * about tuning-parameter selection -- the tuner's problem, and the tuner must use
 * the EFFECTIVE sample count in its CI.)
 *
 * This is also where an over-credited N_eff would have been spent: it shrinks
 * p_bound, the row hits p_goal and stops early, and the campaign banks a bound it
 * never earned.  Hence no special case for HET_ST_TAU_UNRESOLVED -- at N_eff = 1
 * the goal is simply not met and the row keeps running, so the flag is never a
 * stop and never a veto, and it self-clears as the pooled window count grows.
 *
 * p_goal <= 0 means "no bound target" and bound rows run to budget.  There is NO
 * default p_goal here -- a stopping target is a campaign decision, like p_min. */
typedef enum {
  HET_CAMPAIGN_CONTINUE = 0,
  HET_CAMPAIGN_STOP_CONFIRMED,   /* sighting corroborated to HET_CORROB_RUNS runs */
  HET_CAMPAIGN_STOP_BOUND_MET,   /* null row: p_bound <= p_goal                   */
  HET_CAMPAIGN_STOP_BUDGET       /* budget exhausted (the only stop with nothing
                                    to show; the outcome says what it means)      */
} het_campaign_stop_t;

static const char *het_campaign_stop_name(het_campaign_stop_t s) {
  switch (s) {
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
  /* The tier is computed from k_eff's runs, so a sighting the decode guard
     rejected can never de-schedule a test: an artefact must not buy a stop. */
  if (st.tier == HET_SIGHT_CORROBORATED) return HET_CAMPAIGN_STOP_CONFIRMED;
  /* p_bound >= 0 already implies obs == NEVER (it is computed nowhere else); the
     k == 0 guard restates it so the policy reads as it is meant. */
  if (st.k == 0 && p_goal > 0.0 && st.p_bound >= 0.0
      && !(st.flags & HET_ST_BOUND_VACUOUS) && st.p_bound <= p_goal)
    return HET_CAMPAIGN_STOP_BOUND_MET;
  if (budget > 0 && n >= budget) return HET_CAMPAIGN_STOP_BUDGET;
  return HET_CAMPAIGN_CONTINUE;
}

#endif /* HET_VERDICT_H */
