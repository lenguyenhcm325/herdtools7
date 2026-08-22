/* =========================================================================
 * het_verdict.h -- HetLitmus observation record + the reading of a null.
 * litmus7 copies this file verbatim into every emitted harness dir: edit
 * litmus/het-runtime/het_verdict.h, never a harness-dir copy.
 *
 * This harness REPORTS what it observed.  It carries no prediction and never
 * says a result contradicts a model.  A null states what this harness reached --
 * the effort it spent and the liveness its own counters measured -- and NOTHING
 * vouches for it: no rate and no probability is attached to one, falsification
 * being one-sided, so what matters is the possibility of a weak behaviour rather
 * than its probability [Alglave15 sec 4.3 p.585].
 * Design: hetlitmus/docs/00-environment-design.md sec 3.7.
 * ========================================================================= */
#ifndef HET_VERDICT_H
#define HET_VERDICT_H

#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>   /* getenv: the run-time campaign knobs                 */
#include <string.h>   /* memset: het_stats_compute zeroes its own aggregate  */

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
/* "Zero without stress" [Alglave15 sec 4.3.1] is one NVIDIA part's measurement:
   1 only on an NVIDIA row, which names that part when quoting it, so everywhere
   else the run is told the gap rather than being handed somebody else's. */
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
 * THE BUILD FACT, also stamped by the emitter and from EVERY pair: what this
 * binary was built for.  The default below is for the checkers, which compile
 * this header standalone.
 * ------------------------------------------------------------------------- */
#ifndef HET_PAIR_NAME
#define HET_PAIR_NAME "(unstamped CPU ISA x GPU dialect pair)"
#endif

/* ---------------------------------------------------------------------------
 * Knobs of the statistics layer (see its banner further down, and
 * hetlitmus/docs/00-environment-design.md sec 3.7).
 *
 * HET_THETA_DISTINCT (theta_d) is the degeneracy guard's floor
 * (het_cell_degenerate).  Deliberately the literal floor -- 2 = "the decode
 * produced at least two distinct values" -- not a statistical filter: it catches
 * the constant-read artefact [Srivastava24 sec 4.1], and rejecting more than that
 * discards genuine sightings, which one-sided falsification forbids.  Raising it
 * is a hardware-calibration decision. */
#ifndef HET_THETA_DISTINCT
#define HET_THETA_DISTINCT 2
#endif
/* Cells (instance,run) the aggregate can hold.  NUMBER_OF_RUN is 10 by default;
   a campaign that exceeds this is truncated and says so (HET_ST_CELLS_TRUNCATED)
   rather than silently scoring a subset. */
#ifndef HET_STATS_MAX_CELLS
#define HET_STATS_MAX_CELLS 128
#endif

typedef enum { CONF_ROBUST, CONF_ADVISORY, CONF_EXPLORATORY } het_confidence;

/* ---------------------------------------------------------------------------
 * THE RECORD STAMP.  het_obs_record is memset(0) before the emitted driver fills
 * it, so a zeroed record is exactly what an emitter that skipped a field would
 * produce.  rec_magic is the one field a zeroed record cannot forge: het_verdict()
 * refuses to read a record that does not carry it, and a harness whose stamp went
 * missing reports a build bug instead of a result.  The emitter writes the SYMBOL,
 * so a divergence between it and this header is a compile error, not a silent
 * mis-read.  The field names are grepped by recfields. */
#define HET_REC_MAGIC 0x48455431u

/* Which stress mechanisms this BUILD asked for.  A mechanism that produced zero
   work is dead only if it was requested: a deliberately disabled one is not a
   bug, and without the distinction a no-stress baseline run would be COLD
   forever.  The emitter fills this from the compile-time knobs, which is what
   keeps the verdict a pure function of the record, and so decidable from a
   synthetic one. */
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
  /* The CPU-only-cycle flag: 1 when EVERY proc of this test is a CPU proc.  Such
     a test exercises no cross-device path at all -- it is a host-ISA probe on the
     shared allocation -- so what its sighting is about is not what a het cycle's
     is, and the printout says so. */
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
     They are NOT a synonym for cpu_only: a CPU-only cycle on a store-only shape
     still gets a GPU observer lane, so its HET_GPU_LANES is 1.  Key the caveat on
     these counts, never on cpu_only. */
  int gpu_lanes;
  int spin_lanes;
  /* MECHANISM tier: how well this test's cycle can be recovered from the read
     and observer buffers (hetCond.perpetual_class). */
  het_confidence confidence;
  /* REPORTING tier: what a null from this test may be claimed as.  Not the
     mechanism tier -- R is mechanically Advisory but borrows both its synchrony
     point and its ws edge from the fragile observer, so it reports at the 2+2W
     floor.  Classifier and rationale: litmus/hetCond.mli. */
  het_confidence reporting;
  uint64_t N, frames_examined;
  uint64_t target_count_exhaustive, target_count_heuristic;
  /* 0 = the O(N^T_L) ground-truth scan did NOT run at this N (capped by
     HET_EXHAUSTIVE_MAX), so target_count_exhaustive is "not measured", NOT a
     measured zero; reading it as data would manufacture a false "Never".
     het_verdict() raises HET_CV_NO_EXHAUSTIVE when this is 0, and the printout
     says the zero is not a measured one.  On a T_L<=1 shape (no windowed proc)
     every frame is decoded exactly, the O(N) scan is the ground truth, and the
     flag is 1 whatever N is. */
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
  /* GPU stress liveness.  The stress layer leaves no trace in the tested op
     stream by design, so its health is known only if it is measured at run time.
       spin_rendezvous/spin_cap  how the window-opener's spins ended; a mostly
                         cap-released spin is a delay loop, not a rendezvous, and
                         HET_BARRIER_PCT is calibrated against this ratio.
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
       cpu_preload_ops   0 => the preload is inert (a host with no cache
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
  /* The two knobs the interconnect lever is driven with, carried per run so a
     reader sees what the run REALISED, not what it asked for.  noise_ws_mb is the
     noise working set, and it decides whether the noise crosses anything at all:
     below the last-level cache the buffer is served from cache and generates no
     interconnect traffic, so a config that scores well at 8 MB scored a stressor
     that was not running.  The argument is target-independent; the FIGURE is not,
     and the emitter stamps the pair's own into HET_LLC_MB. */
  uint32_t noise_ws_mb, place_mode;
  uint32_t stress_requested;    /* HET_REQ_* bitmask -- see above */
} het_obs_record;

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
 *   HET_RATE       1 => run to budget even once the outcome has been seen, so a
 *                  row that fires yields a RATE instead of a first sighting.
 *                  Sightings then stop nothing; the budget still does
 *   HET_CONFIRM_RUNS  how many runs after the one it fired in a LONE clean sighting
 *                  may hold the row open while it fails to reproduce (default 30,
 *                  floor 1).  This is the wait the corroboration bar costs, and it
 *                  outranks the budget stop -- see the stopping rule at the foot
 *                  of this file
 *   HET_SEED       overrides the compiled HET_SEED base.  THE SCHEDULER MUST
 *                  VARY THIS PER INVOCATION: re-running the same seeds adds no
 *                  fresh phase/seed draws, so pooling two such invocations would
 *                  count one draw twice and report 2R runs of effort for R
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

/* ---------------------------------------------------------------------------
 * THE OUTCOME.  One axis -- was the weak outcome seen, and if not, is this run's
 * zero a datum at all.  No prediction enters here and none is printed: "observed"
 * and "not observed" are the whole vocabulary, and what they are worth against
 * any model is settled offline (hetlitmus/oracle-compare.sh).
 *
 *   HET_OBSERVED    seen.  Believed unconditionally -- falsification is one-sided.
 *   HET_NOT_OBSERVED  not seen, on a run whose every requested mechanism was
 *                   measured alive.  It reports the effort spent and the liveness
 *                   measured, and NOTHING vouches for it: a characterization tool
 *                   states what its harness reached and prices nothing.  Reporting
 *                   a null about one's own reach plainly has a precedent
 *                   [Alglave15 fn.7 p.577].
 *   HET_COLD_INVALID  a mechanism this run rests on was dead, or the record is
 *                   unstamped.  The empty histogram carries no information:
 *                   discard it, never report it as "not observed".
 * ------------------------------------------------------------------------- */
typedef enum {
  HET_OBSERVED = 0,
  HET_NOT_OBSERVED,
  HET_COLD_INVALID
} het_verdict_t;

/* Why a run was DISQUALIFIED (its null is discarded).  Each names a mechanism
   that is dead, not merely suboptimal.
   THE BIT NUMBERS ARE STABLE, for the reason spelled out at the HET_ST_ block
   below: a retired bit is left vacant (0 and 2 today) rather than closed up, so
   an archived word decodes against this list whatever has since left it. */
#define HET_DQ_NO_INTERLEAVING  (1u << 1)  /* the two engines never overlapped    */
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

/* Why a null was CAVEATED (still reportable, but weaker than it looks).  Bit 1 is
   vacant, and stays vacant, for the reason the two blocks above give. */
#define HET_CV_NO_EXHAUSTIVE    (1u << 0)  /* ground-truth scan did not run       */
#define HET_CV_HEURISTIC_SIGHT  (1u << 2)  /* sighting via the windowed heuristic */
#define HET_CV_AFF_FAILED       (1u << 3)  /* pinning is fiction                  */
#define HET_CV_PLACE_REFUSED    (1u << 4)  /* HET_PLACE_LEVER placed nothing      */
#define HET_CV_SPIN_CAP         (1u << 5)  /* a delay loop, not a rendezvous      */
#define HET_CV_UNSTRESSED       (1u << 6)  /* no stress requested at all          */
#define HET_CV_NO_GPU_LANES     (1u << 7)  /* a harness with no GPU test lane has
                                              the GPU scratchpad stress and the
                                              device-scope window-opener
                                              STRUCTURALLY absent -- not dead,
                                              absent.  The null rests on CPU-side
                                              stress alone and must say so.     */

static int het_dead(uint32_t req, uint32_t bit, uint64_t rounds) {
  return (req & bit) && rounds == 0;
}

/* The rule (hetlitmus/docs/00-environment-design.md sec 3.7).  A pure function of
   the record. */
static het_verdict_t het_verdict(const het_obs_record *r,
                                 uint32_t *dq_out, uint32_t *cv_out) {
  uint32_t dq = 0, cv = 0;
  uint32_t req = r->stress_requested;
  het_verdict_t v;

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
     reproducible.  The stress incantations travel with the sighting for the same
     reason absolute counts are reported per incantation combination
     [Alglave15 sec 4.3 Tab.6].  The outcome is unchanged; only its provenance
     travels. */
  if (!r->exhaustive_valid)         cv |= HET_CV_NO_EXHAUSTIVE;
  if (r->cpu_aff_failures > 0)      cv |= HET_CV_AFF_FAILED;
  if (r->place_failures > 0)        cv |= HET_CV_PLACE_REFUSED;
  if (req == 0)                     cv |= HET_CV_UNSTRESSED;
  /* The emitter withholds HET_REQ_GPU_STRESS / HET_REQ_SPIN on a harness whose
     corresponding lane count is 0, because there the mechanism is structurally
     unreachable rather than dead.  Withholding a request silently would be the
     "bump the threshold to get green" move, so it is CAVEATED here instead: the
     reader is told which window-openers could not have run.
     KEYED ON THE LANE COUNTS THE EMITTER ACTUALLY WROTE, not on cpu_only.
     cpu_only is a property of the CYCLE (every proc is a CPU proc); the lane
     counts are a property of the BUILD, and they differ -- a CPU-only cycle still
     gets a GPU observer lane on a store-only shape, so keying the build claim on
     the cycle property asserts a lane count of 0 where it is 1.  A harness that
     merely FORGOT to request a reachable mechanism cannot borrow this excuse: a
     nonzero lane count does not raise the flag for that mechanism, and het_dead()
     disqualifies it. */
  if (r->gpu_lanes == 0 || r->spin_lanes == 0)
                                    cv |= HET_CV_NO_GPU_LANES;
  { uint64_t spins = r->spin_rendezvous + r->spin_cap;
    if (spins && r->spin_rendezvous * 2 < spins) cv |= HET_CV_SPIN_CAP; }

  /* ---- 2. A SIGHTING, believed unconditionally: falsification is one-sided, so
     nothing has to vouch for a positive, and an inert-stress run that saw the
     outcome still saw it.

     The heuristic tally counts here too, and must: on a T_L>=2 shape at
     production N target_count_exhaustive is 0 by construction
     (HET_EXHAUSTIVE_MAX), so keying the sighting off it alone would silently drop
     a real one.  The windowed heuristic searches [c-W, c+W] against the
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
     Channel-aware interleaving-liveness, mirroring het_cell_degenerate: the sync
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
  /* The GPU scratchpad stress, evidenced by het_stress.h's round tally
     (HET_TALLY_STRESS_ROUNDS).  This proves the loop RAN; that it still CONTAINS
     its scratchpad accesses is a static question and neither answer subsumes the
     other, because a layer can be in the source, gone from the emitted GPU code,
     and green on every reading of the source. */
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

  /* ---- 4. The outcome.  A dead mechanism means this run's zero is not a datum;
     anything else is a null, which reports the effort behind it and no more. */
  v = dq ? HET_COLD_INVALID : HET_NOT_OBSERVED;

  if (dq_out) *dq_out = dq;
  if (cv_out) *cv_out = cv;
  return v;
}

static const char *het_verdict_name(het_verdict_t v) {
  switch (v) {
  case HET_OBSERVED:      return "OBSERVED";
  case HET_NOT_OBSERVED:  return "NOT-OBSERVED";
  default:                return "COLD-INVALID";
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
    "skew=[%d,%d] mean=%.3f sd=%.3f "
    "spin=%llu/%llu stress_trunc=%llu do_stress_rounds=%llu req=0x%x "
    "enemies=%u enemy_rounds=%llu enemy_acc=%llu preload=%llu "
    "noise_cpu=%llu/%lluw noise_gpu=%u/%u noise_ws=%uMB place=%u "
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
    _r->noise_ws_mb, _r->place_mode,
    _r->cpu_aff_failures, _r->place_failures);
}

/* ---------------------------------------------------------------------------
 * The reporting contract (hetlitmus/docs/00-environment-design.md sec 3.7): NEVER
 * print a bare "Never".  Every null prints paired with the effort it cost and the
 * liveness this run measured, in absolute numbers, so a reader weighs the zero
 * against what was spent instead of taking the harness's word for it.  Nothing
 * vouches for the harness; the precedent for reporting a null as a fact about
 * one's own reach is [Alglave15 fn.7 p.577].
 * ------------------------------------------------------------------------- */
/* The stress-provenance caveats, printed for a sighting as well as for a null. */
static void het_print_caveats(FILE *_ch, const het_obs_record *_r, uint32_t cv) {
  if (cv & HET_CV_UNSTRESSED)
    fprintf(_ch, "  CAVEAT: no stress was requested.  Kirkham et al., OOPSLA'20, "
                 "sec 6.2 exposed only ONE of six mutants with no stress -- an "
                 "unstressed null is weak evidence whatever else this record "
                 "carries.\n");
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
      "  CAVEAT: HET_GPU_LANES=%d HET_SPIN_LANES=%d.  A mechanism with 0 lanes is "
      "STRUCTURALLY ABSENT, not dead, so it is not counted as requested and its "
      "zero tally disqualifies nothing.  Absent here:%s%s.\n",
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
        "  CAVEAT (cont.): the OTHER mechanism is present (%s lane(s)) and IS "
        "counted as requested -- its zero tally is not excused.\n",
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
    "radius HET_WINDOW is an uncalibrated placeholder.  The window is a strict "
    "subset of the full range: it can MISS cycles, it cannot invent them -- so a "
    "sighting is real and a zero is NOT a measured zero.\n",
    (unsigned long long)_r->N);
}

/* "We did not see it", in the only vocabulary this harness has: the outcome the
   test's condition names, the effort behind the zero, and this run's own liveness
   counters -- printed under every null of every class, since they are all a null
   has.  On a store-only shape the observer IS the liveness channel: with no
   reader, interleavings_detected is structurally 0 and, printed alone, would
   misread as "nothing raced". */
static void het_print_notobserved(FILE *_ch, const het_obs_record *_r) {
  fprintf(_ch,
    "  %s: the weak outcome was NOT observed -- 0 / N=%llu frames (%llu examined); "
    "interleavings_detected=%llu.\n",
    _r->test_name, (unsigned long long)_r->N,
    (unsigned long long)_r->frames_examined,
    (unsigned long long)_r->interleavings_detected);
  if (_r->obs_valid && !_r->sync_valid)
    fprintf(_ch,
      "  the CPU observer resolved %llu distinct GPU store-value(s) across the "
      "window (this store-only shape has no reader, so the observer -- not "
      "interleavings_detected -- is its liveness channel).\n",
      (unsigned long long)_r->observer_unique_count);
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
      /* The CPU-only case says WHAT WAS UNDER TEST, which is not a model call:
         every proc is a CPU proc, so no cross-device path carried this cycle and
         what fired is the host ISA on the shared allocation.  The AMD64 ordering
         rules are stated over normal cacheable naturally-aligned accesses to
         write-back memory [APM sec 7.2]; other memory types may order more
         weakly [APM sec 7.4.2], and a write-combining mapping in particular
         allows stores to complete out of order, while an uncacheable one allows
         none of it [APM Table 7-2].  The MAPPING is therefore part of what this
         row measures, and a sighting rules the uncacheable one out. */
      fprintf(_ch,
        "  ** CPU-ONLY CYCLE: every proc of this test is a CPU proc, so NO "
        "CROSS-DEVICE PATH CARRIED THIS CYCLE -- what fired is the host ISA on the "
        "SHARED ALLOCATION, whose memory TYPE is part of what this row measures: "
        "the sighting rules out an uncacheable (UC) mapping ([APM] Table 7-2) but "
        "does not establish WB over WC.\n");
      /* The `co' edge of a store-only shape comes from an OBSERVER, and this
         harness carries two -- a CPU thread and a GPU lane.  Which one closed the
         cycle decides whether a host-ISA agent observed anything at all, so it is
         printed rather than assumed. */
      if (_r->obs_ws_via_gpu && !_r->obs_ws_via_cpu)
        fprintf(_ch,
          "  ** THE co EDGE CAME ONLY FROM THE GPU OBSERVER (obs_ws_via_gpu=1, "
          "obs_ws_via_cpu=0), AND THE GPU IS NOT AN x86 AGENT: this is a "
          "cross-device-visibility observation, not a datum about the host ISA.  "
          "For that, run a shape with an x86 READER (MP / LB / SB / IRIW), whose "
          "cycle closes inside the CPU.\n");
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

  if (v == HET_COLD_INVALID) {
    fprintf(_ch, "  DISCARD this null -- the harness was not demonstrably hot:\n");
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
      fprintf(_ch, "    - the cache preload was requested but issued ZERO hints\n");
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
      /* "Zero without stress" [Alglave15 Tab. 6] is one NVIDIA part's
         measurement, and it is narrower than "nothing is observed": on that
         chip mp and coRR WERE observed unstressed.  Printing it as a general
         fact on an AMD-tagged run would be borrowing somebody else's number,
         and no equivalent figure is published for that part, so the run is told
         the gap instead.  Keyed on an explicit stamp, never on the shape of a
         string: the emitter sets HET_ALGLAVE_ZERO_MEASURED on the NVIDIA rows,
         which name the measured part when they quote it, and on no others. */
      if (HET_ALGLAVE_ZERO_MEASURED)
        fprintf(_ch, "      On the NVIDIA GTX Titan the inter-CTA lb and sb tests "
                     "were observed 0 per 100k without memory stress, while mp and "
                     "coRR were observed (Alglave ASPLOS'15 Tab. 6)\n");
      else
        fprintf(_ch, "      (Alglave ASPLOS'15 Tab. 6's zero without memory stress "
                     "is an NVIDIA GTX Titan measurement and is NOT claimed for this "
                     "target; no equivalent figure is published for it, so the dead "
                     "mechanism disqualifies this run on its own terms)\n");
    }
    het_print_caveats(_ch, _r, cv);
    return;
  }

  /* The one null frame.  A null is a fact about this harness's reach, not about a
     model, and nothing certifies that reach: the numbers above are the whole
     claim.  Reporting a non-observation as one has precedent [Alglave15 fn.7
     p.577]; the printout carries the citation, not the quotation. */
  fprintf(_ch,
    "  NOT OBSERVED under this effort -- never \"cannot happen\".  "
    "NO RATE AND NO PROBABILITY IS ATTACHED TO THIS NULL, and NOTHING VOUCHES "
    "FOR THE HARNESS THAT DID NOT SEE IT: what this run carries is the effort "
    "above and the liveness %s measured on its own counters.\n",
    HET_PAIR_NAME);
  if (cv & HET_CV_NO_EXHAUSTIVE)
    fprintf(_ch, "    - the O(N^T_L) ground-truth scan did not run at N=%llu, so "
                 "this is NOT a measured zero (the CAVEAT below says why).\n",
            (unsigned long long)_r->N);
  fprintf(_ch,
    "  This is an OBSERVABILITY result about this harness on this hardware and "
    "under this stress -- never a model result -- and it feeds the stress-tuning "
    "priority.  Reporting one that way has precedent: Alglave et al., ASPLOS'15, "
    "fn.7, p.577.\n");
  if (_r->cpu_only)
    /* The CPU-only null: on such a shape the weak outcome is the host store
       buffer, among the most reproducible relaxations the ISA has, so a null is
       evidence about the ALLOCATION rather than about a narrow window. */
    fprintf(_ch,
      "  *** SHARED-ALLOCATION PROBE: this is a CPU-ONLY shape, and its weak "
      "outcome is the host STORE BUFFER -- among the most reproducible relaxations "
      "the ISA has.  A null here is evidence about the SHARED ALLOCATION, not a "
      "narrow window: read it as unresolved until the mapping is known to be WB "
      "(write-back cacheable).  Check PAT/MTRR and /proc/self/smaps for this "
      "allocator before running anything else.\n");

  het_print_scan_caveat(_ch, _r, cv);
  het_print_caveats(_ch, _r, cv);
}

/* =========================================================================
 * THE STATISTICS LAYER -- what a "Never" is worth, and what it is not.  A pure
 * function of an array of het_obs_records (a host-side post-pass), so it is
 * unit-testable from synthetic record streams.
 *
 * The frame is not the trial: a run of N iterations holds N^{T_L} overlapping
 * frames [Melissaris20 sec IV.A], so the replication unit is the (instance,run)
 * cell and Y = 1[target_count >= 1] is what is counted.  A non-observation is
 * reported as a non-observation: no rate and no probability is attached to one,
 * because falsification is one-sided and nothing vouches for the harness that did
 * not see it.  What this layer reports of a null is the effort it cost; of a
 * SIGHTING, how many independent RUNS reproduced it.
 * Design: hetlitmus/docs/00-environment-design.md sec 3.7.
 * ========================================================================= */

/* What the campaign SAW, at the (instance,run) unit. */
typedef enum {
  HET_OBS_VOID = 0,   /* not one usable cell: every run was COLD, so nothing here
                         was measured. */
  HET_OBS_NEVER,      /* k = 0 usable cells observed it                            */
  HET_OBS_SOMETIMES,
  HET_OBS_ALWAYS
} het_obs_class;

/* Corroboration.  A sighting that does not reproduce is the most damaging thing
   this campaign can write down, and the mechanism that would forge one is on
   record: a constant-read artefact -- a reader stuck on its initial value or on
   one value -- yields a spurious 100%/0% [Srivastava24 sec 4.1].  The fix is not
   to suppress sightings -- falsification is one-sided.  "Is the sighting real?"
   (decoder soundness) and "is it reproducible?" (statistical confidence) are two
   questions, so they get two answers: het_verdict() still returns HET_OBSERVED on
   the first sighting, and this tier layers on top and suppresses nothing.

   HET_CORROB_RUNS is the campaign's corroboration bar, and it is a bar and not a
   confidence: two clean runs are what rules out a per-run artefact, and the tier
   says that and no more -- how OFTEN a sighting reproduces is a rate, and this
   layer attaches none. */
#define HET_CORROB_RUNS 2
typedef enum {
  HET_SIGHT_NONE = 0,
  HET_SIGHT_UNCONFIRMED,   /* seen, but in fewer than HET_CORROB_RUNS clean RUNS,
                              or only in degenerate cells: believe it, report it,
                              and reproduce it before writing it up. */
  HET_SIGHT_CORROBORATED   /* >= HET_CORROB_RUNS distinct non-degenerate RUNS */
} het_sighting_tier;

/* Why a statistic is missing or weakened.  Each one is a way this layer could
   silently go constant, so each one is printed.

   THE BIT NUMBERS ARE A WIRE FORMAT: every archived flags=0x... -- transcripts,
   frozen fixtures, thesis-facing evidence -- decodes against this list, and none
   of those numbers can be re-read.  A retired bit is therefore left vacant (0, 1,
   3, 4, 6, 7, 9, 10, 11, 12, 13, 14, 16 today) rather than closed up, so an
   archived value keeps its reading whatever has since left this list.
   Renumbering densely would re-label every archived value in silence.  Add at the
   top; never renumber. */
#define HET_ST_DEGEN_SIGHTING    (1u << 2) /* >=1 sighting failed the decode guard */
#define HET_ST_NO_DECODE_CHANNEL (1u << 5) /* no sync AND no observer: fail closed */
#define HET_ST_CELLS_TRUNCATED   (1u << 8) /* more runs than HET_STATS_MAX_CELLS   */
#define HET_ST_MIXED_POOL       (1u << 15) /* the cells pooled here do NOT all
                                              agree on cpu_only.  Cannot happen
                                              from one harness -- one binary, one
                                              test -- so it means records from
                                              different builds were pooled.
                                              Resolved toward the WEAKER claim
                                              about the compound model (cpu_only
                                              wins), never away from it.       */

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
     The price of the sighting, in the unit the campaign spends, and the one
     number a stop rule that watches for a lone sighting needs. */
  int n_at_first_sight;

  uint64_t N, frames_examined;      /* the effort disclosure                      */
  uint32_t flags;
} het_stats_t;

/* The decode guard: is this cell's decode trustworthy, or could the "sighting" be
   the constant-read artefact?  A ZERO FIELD IS NOT A DEGENERATE DECODE --
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

/* ---------------------------------------------------------------------------
 * THE AGGREGATE.  A pure function of the record stream. */
static void het_stats_compute(const het_obs_record *recs, int n, het_stats_t *st) {
  int    runs[HET_STATS_MAX_CELLS];
  int    allruns[HET_STATS_MAX_CELLS];
  int i, nruns = 0, nall = 0;
  int first;                          /* the first STAMPED cell, or n if there is none */

  memset(st, 0, sizeof *st);
  if (n <= 0) { st->obs = HET_OBS_VOID; return; }
  st->R         = n;
  /* THE STAMP GATES EVERY READ IN THIS FUNCTION.  Below rec_magic a record is
     whatever memset left, so the identity of the pool -- its name, its N, whether
     the cycle is CPU-only -- is read from the first cell that carries the stamp, and
     an unstamped one contributes nothing but its place in the run count R. */
  for (first = 0; first < n && recs[first].rec_magic != HET_REC_MAGIC; first++) ;
  if (first < n) {
    st->test_name = recs[first].test_name;
    st->N         = recs[first].N;
    /* Whether the cycle is CPU-only -- a CHECK rather than an assumption: if the cells
       handed here do not agree on cpu_only they are not one campaign. */
    st->cpu_only  = recs[first].cpu_only;
    { int _i;
      for (_i = first + 1; _i < n; _i++)
        if (recs[_i].rec_magic == HET_REC_MAGIC
            && recs[_i].cpu_only != recs[first].cpu_only) {
          st->flags |= HET_ST_MIXED_POOL;
          /* cpu_only resolves upward, because it names the NARROWER experiment: a
             CPU-only cycle crossed no device boundary, so pooling it with het cells
             must not let the het reading absorb it silently. */
          if (recs[_i].cpu_only) st->cpu_only = 1;
        }
    }
  }
  if (n > HET_STATS_MAX_CELLS) { n = HET_STATS_MAX_CELLS;
                                 st->flags |= HET_ST_CELLS_TRUNCATED; }

  /* ---- 1. The cells.  het_verdict() is already a pure function of the record, so
     the aggregate reuses it rather than re-deriving liveness -- inheriting every
     stress disqualifier for free. */
  for (i = 0; i < n; i++) {
    uint32_t dq = 0, cv = 0;
    het_verdict_t v = het_verdict(&recs[i], &dq, &cv);
    int y, deg;

    /* An UNSTAMPED cell is read by nothing here: het_verdict() stops at rec_magic,
       so every field below it -- the target tallies, the decode channel, the run id,
       the frame count -- is whatever memset left.  Skipped whole, or the aggregate
       would let a harness the emitter built wrong corroborate itself and stop.  It
       is COLD by that same test, so nothing usable is lost. */
    if (dq & HET_DQ_REC_UNSTAMPED) continue;
    y   = het_reported_count(&recs[i]) >= 1;
    deg = het_cell_degenerate(&recs[i]);

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

    st->frames_examined += recs[i].frames_examined;
  }
  st->k_runs = nruns;

  /* ---- 2. The observation class at the (instance,run) unit.
     THE SELECTION EFFECT: a cell is usable when it fired or when its own liveness
     counters were alive, and nothing co-runs whose firing would make "usable"
     outcome-independent.  So the survivors of a row whose liveness rides on the
     outcome are tautologically the runs that fired, and classifying over them
     reports ALWAYS for a row that fired in 3 runs of 10.  The denominator is
     therefore R, the runs EXECUTED, for every row alike.  VOID still turns on
     R_usable: a pool with no usable cell measured nothing at all. */
  { int denom = st->R;
    if (st->R_usable == 0)    st->obs = HET_OBS_VOID;
    else if (st->k == 0)      st->obs = HET_OBS_NEVER;
    else if (st->k >= denom)  st->obs = HET_OBS_ALWAYS;
    else                      st->obs = HET_OBS_SOMETIMES;
  }

  /* ---- 3. The corroboration tier, layered ON TOP of het_verdict()'s immediate
     HET_OBSERVED and never suppressing one.  Distinct RUNS, not merely distinct
     cells: runs are re-seeded and carry a fresh phase/thermal draw, so they are
     the most independent replicates the harness produces. */
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
   the annotation onto its offline comparison table, augmenting it rather than
   replacing it; hetlitmus/campaign.py schedules from it. */
static void het_stats_line(FILE *_ch, const het_stats_t *_s) {
  fprintf(_ch,
    "HetStats %s cpu_only=%d obs=%s "
    "R=%d usable=%d k=%d k_eff=%d k_runs=%d degen=%d first_sight=%d "
    "sighting=%s N=%llu frames=%llu flags=0x%x\n",
    _s->test_name ? _s->test_name : "(none)",
    _s->cpu_only,
    het_obs_class_name(_s->obs), _s->R, _s->R_usable, _s->k, _s->k_eff, _s->k_runs,
    _s->n_degen, _s->n_at_first_sight,
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

  if (_s->obs == HET_OBS_VOID) {
    fprintf(_ch, "  VOID -- not one of the %d runs was usable (every cell COLD).  "
                 "There is nothing here to report: an empty histogram from a dead "
                 "harness is not a non-observation, it is an absence of data.  See "
                 "the per-run HetVerdict lines for which mechanism was dead.\n", _s->R);
    return;
  }

  /* ---- the headline, by observation class.
     A null's two numbers come from two pools: the scoring statement is over the
     usable cells, the effort over the runs executed, which is the pool
     frames_examined is summed over in het_stats_compute.  A discarded run still
     spent its frames; what it did NOT do is license a reading. */
  if (_s->obs == HET_OBS_NEVER) {
    fprintf(_ch,
      "  NOT OBSERVED in any of the %d usable cell(s).  NO RATE AND NO PROBABILITY "
      "IS ATTACHED TO THIS NULL: falsification is one-sided -- \"the possibility, "
      "not probability ... is what matters\" (Alglave et al., ASPLOS'15 4.3, p.585) "
      "-- so what a null carries is the effort behind it, never an interval.\n"
      "  NOTHING VOUCHES FOR THIS HARNESS: what is reported here is the reach it "
      "demonstrated on its own liveness counters, which the per-run HetVerdict "
      "lines carry.\n"
      "  CHARACTERIZATION, NEVER VALIDATION: this harness carries no prediction, so "
      "this null agrees with no model and refutes none -- it reports what this "
      "harness reached on this hardware under this stress.\n"
      "  effort: %d run(s) x N=%llu iterations, %llu frames examined.  Grow R, "
      "NOT N.\n",
      _s->R_usable, _s->R, (unsigned long long)_s->N,
      (unsigned long long)_s->frames_examined);
    return;
  }

  /* ---- observed.  The denominator is R, the runs executed -- see the selection
     effect in het_stats_compute. */
  fprintf(_ch,
    "  OBSERVED in %d of %d run(s), %d of them after the decode guard.  The "
    "denominator is R, the runs EXECUTED: nothing co-runs to make \"usable\" "
    "outcome-independent, so scoring over usable cells alone would report ALWAYS "
    "for a row that fired in only some of them.  NO RATE IS ATTACHED to the "
    "count.\n",
    _s->k, _s->R, _s->k_eff);

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
      fprintf(_ch,
        "  ** SIGHTING %s ** -- the weak outcome was observed in %d distinct "
        "non-degenerate RUN(S) (>= HET_CORROB_RUNS = %d).  A decoder artefact does "
        "not reproduce across re-seeded runs, so the SIGHTING IS REAL and not a "
        "constant-read.  HOW OFTEN it reproduces is NOT reported: this tier is a "
        "count of clean runs and nothing more.\n",
        het_sighting_name(_s->tier), _s->k_runs, (int)HET_CORROB_RUNS);
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
        "campaign should budget for it: grow R, not N.\n",
        _s->n_at_first_sight, _s->R);
    if (_s->cpu_only)
      fprintf(_ch,
        "  ** CPU-ONLY CYCLE: every proc of this test is a CPU proc, so no "
        "cross-device path carried this cycle -- what fired is the host ISA on the "
        "shared allocation, whose memory type is part of what it measures.\n");
  }
}

/* =========================================================================
 * THE CAMPAIGN STOPPING RULE -- where the hardware hours are saved.  ONE rule for
 * every test, because no test carries a prediction to schedule against: a row
 * stops once its sighting is CORROBORATED (nothing more is bought by running a
 * reproduced sighting further), and a row that never fires stops once its budget
 * is spent.  Most nulls converge early and only the stubborn shapes need the long
 * tail, and which shape is stubborn is a property of the chip: SB has the lowest
 * observed rate on two of the three chips of [Kirkham20 sec 4.2 Tab.6] and the
 * highest on the third.
 *
 * A lone clean sighting does not stop the row: one clean run cannot rule out a
 * per-run artefact, so the row keeps running to corroborate -- for confirm_runs runs
 * (HET_CONFIRM_RUNS) MEASURED FROM THE RUN IT FIRED IN, then stops
 * UNCONFIRMED-SIGHTING, which is neither a null nor a corroboration: it says the
 * confirmation window closed on a sighting that did not reproduce, and nothing more.
 * The window opens at the sighting because it exists to buy that sighting its
 * reproduction attempts: measured from run 0 it is already spent when a row fires
 * late, and the row is banked un-reproduced having run none of it.  A degenerate-only
 * sighting is not a clean one, so it takes the null arm and spends its budget.
 *
 * THE WINDOW OUTRANKS THE BUDGET STOP, because a budget caps the cost of a row that
 * is producing nothing and a lone sighting is not nothing -- ending one at BUDGET
 * banks "seen once, stopped looking".  So while a clean sighting is uncorroborated
 * and the window is open, this rule answers CONTINUE, never STOP_BUDGET.  It does
 * not outrank the caller's run capacity: budget is also how many runs the caller can
 * hold (the emitted driver's record array is NUMBER_OF_RUN long).  With budget below
 * the window the in-binary loop ends at its own limit with this rule still saying
 * CONTINUE, so the row prints no stop line and is left for the cross-invocation
 * scheduler to grow with a fresh seed rather than recorded as budget-stopped.
 *
 * rate_mode (HET_RATE=1) measures a rate instead of finding a first sighting:
 * sightings stop nothing and the row runs to its budget like any other.
 *
 * A pure function of the record stream, like het_verdict() and
 * het_stats_compute(), so the in-binary adaptive loop (HET_ADAPTIVE=1) and
 * hetlitmus/campaign.py's cross-invocation loop apply the SAME policy, and both
 * are decidable from a synthetic record stream. */
typedef enum {
  HET_CAMPAIGN_CONTINUE = 0,
  HET_CAMPAIGN_STOP_CORROBORATED, /* sighting reproduced in HET_CORROB_RUNS runs  */
  HET_CAMPAIGN_STOP_UNCONFIRMED,  /* a LONE clean sighting the confirmation window
                                     closed on without corroborating it           */
  HET_CAMPAIGN_STOP_BUDGET        /* budget exhausted (the only stop with nothing
                                     to show; the outcome says what it means)     */
} het_campaign_stop_t;

/* hetlitmus/campaign.py mirrors these strings (its check_flag_mirror pins them
   against this switch), so they are an interface and not a printout. */
static const char *het_campaign_stop_name(het_campaign_stop_t s) {
  switch (s) {
  case HET_CAMPAIGN_STOP_CORROBORATED: return "CORROBORATED";
  case HET_CAMPAIGN_STOP_UNCONFIRMED:  return "UNCONFIRMED-SIGHTING";
  case HET_CAMPAIGN_STOP_BUDGET:       return "BUDGET";
  default:                             return "CONTINUE";
  }
}

/* UNCONFIRMED-SIGHTING is the one stop whose name is not its meaning, so it is the
   one that carries a sentence -- and the sentence says what happened and stops
   there.  Whether the outcome should have been seen is not a question this harness
   answers (the comparison is offline, hetlitmus/oracle-compare.sh). */
static const char *het_campaign_stop_why(het_campaign_stop_t s) {
  return (s == HET_CAMPAIGN_STOP_UNCONFIRMED)
    ? "the confirmation window closed on a lone clean sighting that did not reproduce"
    : "";
}

static het_campaign_stop_t het_campaign_should_stop(const het_obs_record *recs,
                                                    int n, int budget,
                                                    int rate_mode,
                                                    int confirm_runs) {
  het_stats_t st;
  if (n <= 0) return HET_CAMPAIGN_CONTINUE;
  het_stats_compute(recs, n, &st);
  /* A window shorter than one run is not a window, and a caller that asks for one
     gets the shortest real one rather than an unbounded wait. */
  if (confirm_runs < 1) confirm_runs = 1;
  /* k_eff counts sightings that PASSED the decode guard, so an artefact can neither
     stop a row here nor hold one open: a degenerate-only sighting leaves k_eff at 0
     and takes the null arm below (st.tier alone would not -- it is set by k). */
  if (st.k_eff > 0 && !rate_mode) {
    if (st.tier == HET_SIGHT_CORROBORATED) return HET_CAMPAIGN_STOP_CORROBORATED;
    /* THE WINDOW ELAPSES FROM THE SIGHTING.  n_at_first_sight is the run count at
       the first clean sighting, one-based and > 0 whenever k_eff > 0, so this is the
       runs spent SINCE it; against n alone a row firing past confirm_runs would be
       banked UNCONFIRMED with zero runs to reproduce in.  Both counts are runs: the
       caller passes one record per run, as the budget arm below also assumes. */
    if (n - st.n_at_first_sight >= confirm_runs)
      return HET_CAMPAIGN_STOP_UNCONFIRMED;
    return HET_CAMPAIGN_CONTINUE;               /* outranks the budget stop below */
  }
  if (budget > 0 && n >= budget) return HET_CAMPAIGN_STOP_BUDGET;
  return HET_CAMPAIGN_CONTINUE;
}

#endif /* HET_VERDICT_H */
