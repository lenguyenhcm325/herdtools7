/* =========================================================================
 * het_verdict.h -- the observation record and the outcome rule.
 * Emitted verbatim into every harness dir; edit litmus/het-runtime/het_verdict.h,
 * never a harness-dir copy.
 * This harness reports what it observed: it carries no prediction and never says
 * a result contradicts a model.  A null states the effort the run spent and the
 * liveness its own counters measured, and NOTHING vouches for it -- no rate and
 * no probability attaches to one [Alglave15 sec 4.3 p.585].
 * The rule and every sentence it prints: hetlitmus/docs/harness-reporting.md.
 * ========================================================================= */
#ifndef HET_VERDICT_H
#define HET_VERDICT_H

#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>   /* getenv: the run-time campaign knobs                 */
#include <string.h>   /* memset: het_stats_compute zeroes its own aggregate  */

/* These name the mechanism and NEVER a part; the pair is HET_PAIR_NAME.
   hetlitmus/docs/het-emission.md "The pair a harness names". */
#define HET_LINK_NAME "host-device interconnect"  /* no leading article: sites add it */
#define HET_HOST_HALF "the host half"
#define HET_DEV_HALF "the device half"
/* Default when the dialect stamps no lever
   (hetlitmus/docs/het-emission.md, "The pair a harness names"). */
#ifndef HET_PLACE_LEVER
#define HET_PLACE_LEVER "the page-placement lever"
#endif

/* What this binary was built for; the emitter stamps it from every pair.  The
   default serves a standalone compile of this header. */
#ifndef HET_PAIR_NAME
#define HET_PAIR_NAME "(unstamped CPU ISA x GPU dialect pair)"
#endif

/* Cells (instance,run) the aggregate can hold.  A campaign with more runs than
   this is truncated and flags HET_ST_CELLS_TRUNCATED rather than silently
   scoring a subset. */
#ifndef HET_STATS_MAX_CELLS
#define HET_STATS_MAX_CELLS 128
#endif

/* Share of N that may be discarded at the rendezvous before the run itself is
   discarded: past it the two sides mostly did not run together, so the
   iterations that did are not a sample of the window the test is about.  The
   caps producing the discards are het_rdv.h's; this is the budget the rule
   spends. */
#ifndef HET_RDV_MAX_DISCARD_PCT
#define HET_RDV_MAX_DISCARD_PCT 50
#endif

/* het_obs_record is memset(0) before the driver fills it, so rec_magic is the one
   field a zeroed record cannot forge: het_verdict() refuses a record without it,
   and a harness whose stamp went missing reports a build bug, not a result.  The
   emitter writes the symbol, so a divergence is a compile error. */
#define HET_REC_MAGIC 0x48455431u

/* Which stress mechanisms this build asked for: a zero tally is dead only where
   the mechanism was requested, or a no-stress baseline would be COLD forever.
   Bit numbers are a wire format, vacancies (1) and all -- add at the top,
   never renumber (hetlitmus/docs/harness-reporting.md sec 7). */
#define HET_REQ_GPU_STRESS  (1u << 0)   /* HET_PRE_STRESS_PCT | HET_MEM_STRESS_PCT */
#define HET_REQ_CPU_ENEMY   (1u << 2)   /* HET_CPU_ENEMIES                         */
#define HET_REQ_CPU_PRELOAD (1u << 3)   /* HET_CPU_PRELOAD_PCT && _PRELOAD_LIVE    */
#define HET_REQ_NOISE_CPU   (1u << 4)   /* HET_NOISE_CPU                           */
#define HET_REQ_NOISE_GPU   (1u << 5)   /* HET_NOISE_GPU_BLOCKS                    */

typedef struct het_obs_record {
  /* HET_REC_MAGIC, or this record is not read at all. */
  uint32_t rec_magic;
  const char *test_name; int instance_id; int run_id;
  /* 1 when EVERY proc of this test is a CPU proc: no cross-device path carries
     the cycle, so what a sighting is about is the host ISA on the shared
     allocation, and the printout says so. */
  int cpu_only;
  /* GPU test lanes in this build.  At 0 the stress round loop exits before its
     body runs once, so the mechanism is structurally absent; key that caveat
     here and NEVER on cpu_only, which is a property of the cycle. */
  int gpu_lanes;
  uint64_t N;
  /* The readout counts iterations, never searches: one iteration, one slot, one
     outcome vector, so target_count <= iters_scored <= N, and discarded (a
     participant never started it) + scored = N once the readout ran. */
  uint64_t iters_scored;
  uint64_t iters_discarded;
  uint64_t target_count;
  /* rdv_valid says the readout ran, which separates the counts above from
     memset zeros.  rdv_cap_cpu / rdv_cap_gpu count cap expiries per participant
     per iteration, so they neither partition nor bound iters_discarded.
     cap_cpu / cap_gpu are the waits this run used, and cap_calibrated is 0
     until they are measured on the target. */
  int rdv_valid;
  uint64_t rdv_cap_cpu, rdv_cap_gpu;
  uint32_t cap_cpu, cap_gpu;
  int cap_calibrated;
  /* 0 = every scored iteration read back the SAME outcome vector, which is the
     constant-read artefact [Srivastava24 sec 4.1].  Caveated, never suppressed. */
  int outcomes_vary;
  /* GPU stress liveness -- the ONLY run-time evidence the layer ran, since it
     leaves no trace in the tested op stream.  stress_truncated: lanes that
     stopped stressing while the test still ran.  gpu_stress_rounds: max rounds
     one het_do_stress call completed; stress blocks fill what the co-residency
     cap leaves over the test lanes, so that cap squeezes them to zero first. */
  uint64_t stress_truncated;
  uint64_t gpu_stress_rounds;
  /* CPU + interconnect liveness, same argument, for the levers the GPU tallies
     do not cover.  A zero rounds/ops field means the mechanism never ran; a
     nonzero *_failures field means a pin or a placement was refused rather than
     applied, so the topology is not the one being tuned. */
  uint64_t cpu_enemy_rounds, cpu_enemy_accesses, cpu_preload_ops;
  uint64_t noise_cpu_rounds, noise_cpu_words;
  uint32_t noise_gpu_blocks, noise_gpu_rounds;
  uint32_t cpu_enemies, cpu_aff_failures, place_failures;
  /* What the run REALISED, not what it asked for.  A noise working set below the
     last-level cache is served from cache and crosses nothing, so a config that
     scores well at 8 MB scored a stressor that was not running (HET_LLC_MB,
     het_cpu_stress.h). */
  uint32_t noise_ws_mb, place_mode;
  uint32_t stress_requested;    /* HET_REQ_* bitmask -- see above */
} het_obs_record;

/* ---------------------------------------------------------------------------
 * Run-time knobs: getenv, never a -D the device code can see (nvcc folds a
 * compile-time knob and removes the only branch with side effects).
 * hetlitmus/campaign.py retunes them per invocation without a rebuild; unset
 * means the compiled default.
 *   HET_RUNS_MAX      runs this invocation, clamped to the compiled
 *                     NUMBER_OF_RUN (the record array is that size); R grows by
 *                     re-invoking with a fresh HET_SEED
 *   HET_ADAPTIVE      1 => consult het_campaign_should_stop() after every run
 *   HET_RATE          1 => run to budget even after a sighting, for a rate
 *   HET_CONFIRM_RUNS  runs a lone clean sighting may hold the row open for,
 *                     counted from the run it fired in (default 30, floor 1)
 *   HET_SEED          the seed base.  VARY IT per invocation: replaying seeds
 *                     draws no fresh phase, so pooling two such invocations
 *                     counts one draw twice
 * ------------------------------------------------------------------------- */
static long het_env_long(const char *name, long dflt) {
  const char *v = getenv(name);
  char *end;
  long x;
  if (v == NULL || *v == '\0') return dflt;
  x = strtol(v, &end, 0);
  return (end == v) ? dflt : x;
}

/* The outcome: one axis -- was the weak outcome seen, and if not, is this run's
 * zero a datum at all.  A dead mechanism or an unstamped record makes it
 * HET_COLD_INVALID, NEVER "not observed".
 * hetlitmus/docs/harness-reporting.md sec 2. */
typedef enum {
  HET_OBSERVED = 0,
  HET_NOT_OBSERVED,
  HET_COLD_INVALID
} het_verdict_t;

/* Why a run was DISQUALIFIED (its null is discarded): each names a mechanism
   that is dead, not merely suboptimal.  Vacant bits: 0, 1, 2, 4, 11. */
#define HET_DQ_STRESS_TRUNCATED (1u << 3)  /* stress stopped mid-run              */
#define HET_DQ_CPU_ENEMY_DEAD   (1u << 5)
#define HET_DQ_CPU_PRELOAD_DEAD (1u << 6)
#define HET_DQ_NOISE_CPU_DEAD   (1u << 7)  /* NOT interconnect-stressed           */
#define HET_DQ_NOISE_GPU_DEAD   (1u << 8)
#define HET_DQ_GPU_STRESS_DEAD  (1u << 9)  /* het_do_stress requested, never ran  */
/* No rec_magic, so a zeroed record reads as a live one: fail closed, loudly. */
#define HET_DQ_REC_UNSTAMPED    (1u << 10)
/* The readout did not run, nothing was scored, or more than
   HET_RDV_MAX_DISCARD_PCT of N was discarded at the cap. */
#define HET_DQ_RDV_DEAD         (1u << 12)

/* Why a null was CAVEATED (reportable, but weaker than it looks).  Vacant
   bits: 0, 1, 2, 5. */
#define HET_CV_AFF_FAILED       (1u << 3)  /* pinning is fiction                  */
#define HET_CV_PLACE_REFUSED    (1u << 4)  /* HET_PLACE_LEVER placed nothing      */
#define HET_CV_UNSTRESSED       (1u << 6)  /* no stress requested at all          */
#define HET_CV_NO_GPU_LANES     (1u << 7)  /* no GPU test lane: the scratchpad
                                              stress is structurally absent    */
#define HET_CV_ONE_OUTCOME      (1u << 8)  /* every scored iteration read back the
                                              same outcome vector               */
#define HET_CV_RDV_UNCALIBRATED (1u << 9)  /* the rendezvous caps are het_rdv.h's
                                              placeholders, not a measurement   */

static int het_dead(uint32_t req, uint32_t bit, uint64_t rounds) {
  return (req & bit) && rounds == 0;
}

/* The rule (hetlitmus/docs/harness-reporting.md sec 2).  A pure function of
   the record. */
static het_verdict_t het_verdict(const het_obs_record *r,
                                 uint32_t *dq_out, uint32_t *cv_out) {
  uint32_t dq = 0, cv = 0;
  uint32_t req = r->stress_requested;
  het_verdict_t v;

  /* ---- 0. FAIL CLOSED on an unstamped record, before anything else: every field
     below rec_magic is then whatever memset left. */
  if (r->rec_magic != HET_REC_MAGIC) {
    if (dq_out) *dq_out = HET_DQ_REC_UNSTAMPED;
    if (cv_out) *cv_out = 0;
    return HET_COLD_INVALID;
  }

  /* ---- 1. Caveats FIRST, because a sighting needs them too: a weak behaviour
     observed under a stress config nobody recorded is not reproducible.  Only
     the provenance travels; the outcome is unchanged. */
  if (r->iters_scored > 0 && !r->outcomes_vary)
                                    cv |= HET_CV_ONE_OUTCOME;
  if (!r->cap_calibrated)           cv |= HET_CV_RDV_UNCALIBRATED;
  if (r->cpu_aff_failures > 0)      cv |= HET_CV_AFF_FAILED;
  if (r->place_failures > 0)        cv |= HET_CV_PLACE_REFUSED;
  if (req == 0)                     cv |= HET_CV_UNSTRESSED;
  /* The emitter withholds HET_REQ_GPU_STRESS at 0 lanes, where the mechanism is
     structurally unreachable rather than dead, so it is caveated here instead.
     Keyed on the lane count the emitter wrote, NEVER on cpu_only: a harness that
     merely forgot to request a reachable mechanism keeps its lane count and is
     disqualified by het_dead(). */
  if (r->gpu_lanes == 0)            cv |= HET_CV_NO_GPU_LANES;

  /* ---- 2. A SIGHTING, believed unconditionally: an inert-stress run that saw
     the outcome still saw it. */
  if (r->target_count > 0) {
    if (dq_out) *dq_out = 0;
    if (cv_out) *cv_out = cv;
    return HET_OBSERVED;
  }

  /* ---- 3. Liveness: is this run's null even a datum?  Starting with the
     partner's, which no stress tally covers -- a run whose iterations mostly
     ended at the cap has an empty histogram about the rendezvous rather than
     about the memory model. */
  if (!r->rdv_valid || r->iters_scored == 0 ||
      r->iters_discarded * 100 > r->N * HET_RDV_MAX_DISCARD_PCT)
                                                  dq |= HET_DQ_RDV_DEAD;
  if (r->stress_truncated > 0)                    dq |= HET_DQ_STRESS_TRUNCATED;
  /* het_stress.h's round tally says the loop RAN.  Whether it still contains its
     scratchpad accesses is a static question, and neither answer subsumes the
     other: a layer can be in the source and gone from the emitted GPU code. */
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

  /* ---- 4. A dead mechanism means this run's zero is not a datum. */
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

static void het_obs_record_print(FILE *_ch, const het_obs_record *_r) {
  fprintf(_ch,
    "HetObs %s cpu_only=%d "
    "inst=%d run=%d N=%llu scored=%llu discarded=%llu target=%llu "
    "cap_cpu=%llu/%u cap_gpu=%llu/%u calibrated=%d vary=%d "
    "stress_trunc=%llu do_stress_rounds=%llu req=0x%x "
    "enemies=%u enemy_rounds=%llu enemy_acc=%llu preload=%llu "
    "noise_cpu=%llu/%lluw noise_gpu=%u/%u noise_ws=%uMB place=%u "
    "aff_fail=%u place_fail=%u\n",
    _r->test_name,
    _r->cpu_only,
    _r->instance_id, _r->run_id,
    (unsigned long long)_r->N,
    (unsigned long long)_r->iters_scored,
    (unsigned long long)_r->iters_discarded,
    (unsigned long long)_r->target_count,
    (unsigned long long)_r->rdv_cap_cpu, _r->cap_cpu,
    (unsigned long long)_r->rdv_cap_gpu, _r->cap_gpu,
    _r->cap_calibrated,
    _r->outcomes_vary,
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

/* The reporting contract: NEVER a bare "Never".  Every null prints paired with
   the effort it cost and the liveness this run measured, in absolute numbers.
   hetlitmus/docs/harness-reporting.md sec 4. */
/* The stress-provenance caveats, printed for a sighting as well as for a null. */
static void het_print_caveats(FILE *_ch, const het_obs_record *_r, uint32_t cv) {
  if (cv & HET_CV_UNSTRESSED)
    fprintf(_ch, "  CAVEAT: no stress was requested.  Kirkham et al., OOPSLA'20, "
                 "sec 6.2 exposed only ONE of six mutants with no stress -- an "
                 "unstressed null is weak evidence whatever else this record "
                 "carries.\n");
  if (cv & HET_CV_ONE_OUTCOME)
    fprintf(_ch, "  CAVEAT: every one of the %llu scored iteration(s) read back "
                 "the SAME outcome vector.  A decode that never varies is the "
                 "constant-read artefact Srivastava et al. observed (sec 4.1) -- "
                 "a reader stuck on init or on one value -- so this run measured "
                 "one thing %llu times.\n",
            (unsigned long long)_r->iters_scored,
            (unsigned long long)_r->iters_scored);
  if (cv & HET_CV_RDV_UNCALIBRATED)
    fprintf(_ch, "  CAVEAT: the rendezvous caps are PLACEHOLDERS (cpu=%u, gpu=%u "
                 "polls), not a measurement on this target, so the %llu discarded "
                 "iteration(s) price a wait nobody calibrated: a shorter cap "
                 "discards iterations the two sides would have shared, a longer "
                 "one spends the run waiting for a partner that is not coming.\n",
            _r->cap_cpu, _r->cap_gpu,
            (unsigned long long)_r->iters_discarded);
  if (cv & HET_CV_AFF_FAILED)
    fprintf(_ch, "  CAVEAT: %u sched_setaffinity call(s) FAILED -- the pinning is "
                 "fiction and the stress topology is not the one being tuned.\n",
            _r->cpu_aff_failures);
  if (cv & HET_CV_PLACE_REFUSED)
    fprintf(_ch, "  CAVEAT: %s was REFUSED -- HET_PLACE placed nothing.\n",
            HET_PLACE_LEVER);
  if (cv & HET_CV_NO_GPU_LANES)
    fprintf(_ch,
      "  CAVEAT: HET_GPU_LANES=%d.  A mechanism with 0 lanes is STRUCTURALLY "
      "ABSENT, not dead, so the GPU scratchpad stress is not counted as "
      "requested and its zero tally disqualifies nothing.\n",
      _r->gpu_lanes);
}

/* The stress incantations, travelling with every reported outcome. */
static void het_print_config(FILE *_ch, const het_obs_record *_r) {
  fprintf(_ch,
    "  config: stress_requested=0x%x do_stress_rounds=%llu "
    "enemies=%u enemy_rounds=%llu preload=%llu noise=%llu/%u (%u MB) place=%u\n",
    _r->stress_requested,
    (unsigned long long)_r->gpu_stress_rounds,
    _r->cpu_enemies,
    (unsigned long long)_r->cpu_enemy_rounds,
    (unsigned long long)_r->cpu_preload_ops,
    (unsigned long long)_r->noise_cpu_rounds, _r->noise_gpu_blocks,
    _r->noise_ws_mb, _r->place_mode);
}

/* The outcome the condition names and the effort behind the zero, under every
   null of every class. */
static void het_print_notobserved(FILE *_ch, const het_obs_record *_r) {
  fprintf(_ch,
    "  %s: the weak outcome was NOT observed -- 0 / N=%llu iterations "
    "(%llu scored, %llu discarded at the rendezvous).\n",
    _r->test_name, (unsigned long long)_r->N,
    (unsigned long long)_r->iters_scored,
    (unsigned long long)_r->iters_discarded);
}

static void het_verdict_print(FILE *_ch, const het_obs_record *_r) {
  uint32_t dq = 0, cv = 0;
  het_verdict_t v = het_verdict(_r, &dq, &cv);
  unsigned long long _n = (unsigned long long)_r->N;
  unsigned long long _hits = (unsigned long long)_r->target_count;
  double _pct = _r->iters_scored
    ? (100.0 * (double)_hits / (double)_r->iters_scored) : 0.0;

  fprintf(_ch, "HetVerdict %s%s run=%d: %s\n",
          _r->test_name,
          _r->cpu_only ? " CPU-ONLY" : "",
          _r->run_id, het_verdict_name(v));

  /* ---- 0. Unstamped: nothing below rec_magic was measured.  Say only that. */
  if (dq & HET_DQ_REC_UNSTAMPED) {
    fprintf(_ch,
      "  *** THIS RECORD CARRIES NO STAMP (rec_magic != HET_REC_MAGIC) ***\n"
      "  The emitted driver did not stamp it, so every count, flag and liveness "
      "tally read here is a memset zero rather than a measurement, and a zeroed "
      "record is indistinguishable from a harness that ran and saw nothing.  This "
      "is a BUILD BUG, not a result.  Rebuild; do not report.\n");
    return;
  }

  /* ---- The sighting, believed unconditionally. */
  if (v == HET_OBSERVED) {
    fprintf(_ch,
      "  ** %s: the weak outcome was OBSERVED in %llu of the %llu scored "
      "iteration(s) of N=%llu (%.4f%%).\n"
      "  Report it as what %s exhibited under this harness, this stress and this "
      "%s path.  It is an OBSERVATION: this harness carries no prediction, so "
      "nothing here confirms or contradicts any model.  Comparing it against a "
      "verdicts file the reader supplies is an offline step.\n",
      _r->test_name, _hits,
      (unsigned long long)_r->iters_scored, _n, _pct,
      HET_PAIR_NAME, HET_LINK_NAME);
    if (_r->cpu_only) {
      fprintf(_ch,
        "  ** CPU-ONLY CYCLE: every proc of this test is a CPU proc, so NO "
        "CROSS-DEVICE PATH CARRIED THIS CYCLE -- what fired is the host ISA on the "
        "SHARED ALLOCATION, whose memory TYPE is part of what this row measures: "
        "the sighting rules out an uncacheable (UC) mapping ([APM] Table 7-2) but "
        "does not establish WB over WC.\n");
    }
    het_print_config(_ch, _r);
    het_print_caveats(_ch, _r, cv);
    return;
  }

  /* ---- Not observed.  It NEVER prints alone. */
  het_print_notobserved(_ch, _r);

  if (v == HET_COLD_INVALID) {
    fprintf(_ch, "  DISCARD this null -- the harness was not demonstrably hot:\n");
    if (dq & HET_DQ_RDV_DEAD)
      fprintf(_ch, "    - the RENDEZVOUS: %llu of N=%llu iteration(s) scored, "
                   "%llu discarded at the cap (caps %u/%u polls, budget "
                   "%d%%)%s.  The cap expired %llu time(s) on a CPU participant "
                   "and %llu time(s) on a GPU lane, counted per participant per "
                   "iteration: an iteration no side reached counts on every one "
                   "of them, so the two neither partition nor bound the "
                   "discards.  A timed-out rendezvous is a DEAD PARTNER or "
                   "a cap set too short, never a non-observation: the two sides "
                   "did not run the iteration together, so there was no window "
                   "for the outcome to appear in\n",
              (unsigned long long)_r->iters_scored,
              (unsigned long long)_r->N,
              (unsigned long long)_r->iters_discarded,
              _r->cap_cpu, _r->cap_gpu, (int)HET_RDV_MAX_DISCARD_PCT,
              _r->rdv_valid ? "" : " -- and the readout never ran at all",
              (unsigned long long)_r->rdv_cap_cpu,
              (unsigned long long)_r->rdv_cap_gpu);
    if (dq & HET_DQ_STRESS_TRUNCATED)
      fprintf(_ch, "    - stress_truncated=%llu: stress STOPPED while tested "
                   "lanes were still running\n",
              (unsigned long long)_r->stress_truncated);
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
    if (dq & HET_DQ_GPU_STRESS_DEAD)
      fprintf(_ch, "    - the GPU scratchpad stress was requested "
                   "(HET_PRE_STRESS_PCT/HET_MEM_STRESS_PCT) but het_do_stress "
                   "completed ZERO rounds: it never ran\n");
    het_print_caveats(_ch, _r, cv);
    return;
  }

  /* The one null frame. */
  fprintf(_ch,
    "  NOT OBSERVED under this effort -- never \"cannot happen\".  "
    "NO RATE AND NO PROBABILITY IS ATTACHED TO THIS NULL, and NOTHING VOUCHES "
    "FOR THE HARNESS THAT DID NOT SEE IT: what this run carries is the effort "
    "above and the liveness %s measured on its own counters.\n",
    HET_PAIR_NAME);
  fprintf(_ch,
    "  This is an OBSERVABILITY result about this harness on this hardware and "
    "under this stress -- never a model result -- and it feeds the stress-tuning "
    "priority.  Reporting one that way has precedent: Alglave et al., ASPLOS'15, "
    "fn.7, p.577.\n");
  if (_r->cpu_only)
    fprintf(_ch,
      "  *** SHARED-ALLOCATION PROBE: this is a CPU-ONLY shape, and its weak "
      "outcome is the host STORE BUFFER -- among the most reproducible relaxations "
      "the ISA has.  A null here is evidence about the SHARED ALLOCATION, not a "
      "narrow window: read it as unresolved until the mapping is known to be WB "
      "(write-back cacheable).  Check PAT/MTRR and /proc/self/smaps for this "
      "allocator before running anything else.\n");

  het_print_caveats(_ch, _r, cv);
}

/* The statistics layer -- a pure function of an array of het_obs_records, run
 * host-side after the campaign.  The iteration is not the trial: the replication
 * unit is the (instance,run) cell and Y = 1[target_count >= 1] is counted.
 * hetlitmus/docs/harness-reporting.md sec 5. */

/* What the campaign SAW, at the (instance,run) unit. */
typedef enum {
  HET_OBS_VOID = 0,   /* not one usable cell: nothing here was measured           */
  HET_OBS_NEVER,      /* k = 0 usable cells observed it                            */
  HET_OBS_SOMETIMES,
  HET_OBS_ALWAYS
} het_obs_class;

/* Corroboration layers ON TOP of het_verdict()'s HET_OBSERVED and suppresses
   nothing: HET_CORROB_RUNS is a bar in clean runs, not a confidence, and a
   constant-read artefact forges a sighting [Srivastava24 sec 4.1].
   hetlitmus/docs/harness-reporting.md sec 5. */
#define HET_CORROB_RUNS 2
typedef enum {
  HET_SIGHT_NONE = 0,
  HET_SIGHT_UNCONFIRMED,   /* seen in fewer than HET_CORROB_RUNS clean runs, or
                              only in degenerate cells: reproduce it. */
  HET_SIGHT_CORROBORATED   /* >= HET_CORROB_RUNS distinct non-degenerate RUNS */
} het_sighting_tier;

/* Why a statistic is missing or weakened -- each is a way this layer could go
   silently constant, so each is printed.  Vacant bits: 0, 1, 3-7, 9-14, 16. */
#define HET_ST_DEGEN_SIGHTING    (1u << 2) /* >=1 sighting failed the decode guard */
#define HET_ST_CELLS_TRUNCATED   (1u << 8) /* more runs than HET_STATS_MAX_CELLS   */
#define HET_ST_MIXED_POOL       (1u << 15) /* pooled cells do NOT agree on
                                              cpu_only; the weaker one wins    */

typedef struct het_stats {
  const char *test_name;
  int cpu_only;
  het_obs_class obs;
  het_sighting_tier tier;

  int R;              /* cells supplied (= NUMBER_OF_RUN; one instance/binary)    */
  int R_usable;       /* cells whose het_verdict() is not COLD-INVALID            */
  int k;              /* cells with Y = 1[target_count >= 1]                      */
  int k_eff;          /* ... of those, the ones that pass the decode guard        */
  int k_runs;         /* distinct RUNS among them (the most independent draws)    */
  int n_degen;        /* sightings REJECTED by the guard (reported, never hidden) */
  /* Distinct runs consumed when the FIRST clean sighting landed; 0 = none did.
     The price of the sighting, in the unit the campaign spends. */
  int n_at_first_sight;

  uint64_t N, iters_scored, iters_discarded;   /* the effort disclosure          */
  uint32_t flags;
} het_stats_t;

/* The decode guard: could this cell's sighting be the constant-read artefact
   [Srivastava24 sec 4.1]?  A readout that never ran, a cell that scored nothing
   and one whose every iteration read back the same vector all fail closed.  The
   sighting is still REPORTED; it just does not count toward corroboration. */
static int het_cell_degenerate(const het_obs_record *r) {
  return !r->rdv_valid || (r->iters_scored == 0) || !r->outcomes_vary;
}

/* The aggregate: a pure function of the record stream. */
static void het_stats_compute(const het_obs_record *recs, int n, het_stats_t *st) {
  int    runs[HET_STATS_MAX_CELLS];
  int    allruns[HET_STATS_MAX_CELLS];
  int i, nruns = 0, nall = 0;
  int first;                          /* the first STAMPED cell, or n if there is none */

  memset(st, 0, sizeof *st);
  if (n <= 0) { st->obs = HET_OBS_VOID; return; }
  st->R         = n;
  /* The stamp gates every read here: the pool's identity comes from the first
     STAMPED cell, and an unstamped one contributes only its place in R. */
  for (first = 0; first < n && recs[first].rec_magic != HET_REC_MAGIC; first++) ;
  if (first < n) {
    st->test_name = recs[first].test_name;
    st->N         = recs[first].N;
    /* Cells that do not agree on cpu_only are not one campaign. */
    st->cpu_only  = recs[first].cpu_only;
    { int _i;
      for (_i = first + 1; _i < n; _i++)
        if (recs[_i].rec_magic == HET_REC_MAGIC
            && recs[_i].cpu_only != recs[first].cpu_only) {
          st->flags |= HET_ST_MIXED_POOL;
          /* cpu_only resolves upward: it names the NARROWER experiment, and a het
             reading must not absorb it silently. */
          if (recs[_i].cpu_only) st->cpu_only = 1;
        }
    }
  }
  if (n > HET_STATS_MAX_CELLS) { n = HET_STATS_MAX_CELLS;
                                 st->flags |= HET_ST_CELLS_TRUNCATED; }

  /* ---- 1. The cells, scored through het_verdict() rather than by re-deriving
     liveness, so every stress disqualifier is inherited. */
  for (i = 0; i < n; i++) {
    uint32_t dq = 0, cv = 0;
    het_verdict_t v = het_verdict(&recs[i], &dq, &cv);
    int y, deg;

    /* An UNSTAMPED cell is skipped whole: every field below rec_magic is whatever
       memset left, and reading it would let a mis-built harness corroborate
       itself and stop.  It is cold anyway, so nothing usable is lost. */
    if (dq & HET_DQ_REC_UNSTAMPED) continue;
    y   = recs[i].target_count >= 1;
    deg = het_cell_degenerate(&recs[i]);

    /* A sighting is never COLD, so this count can never discard one. */
    if (v != HET_COLD_INVALID) st->R_usable++;

    /* Runs consumed so far, over EVERY cell and not only the sighting ones:
       n_at_first_sight is a price in runs actually spent. */
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

    st->iters_scored += recs[i].iters_scored;
    st->iters_discarded += recs[i].iters_discarded;
  }
  st->k_runs = nruns;

  /* ---- 2. The observation class.  The denominator is R, the runs EXECUTED: a
     cell is usable when it fired or when its own liveness counters were alive,
     and nothing co-runs to make "usable" outcome-independent, so scoring over
     usable cells alone would report Always for a row that fired in 3 of 10.
     Void still turns on R_usable: such a pool measured nothing at all. */
  { int denom = st->R;
    if (st->R_usable == 0)    st->obs = HET_OBS_VOID;
    else if (st->k == 0)      st->obs = HET_OBS_NEVER;
    else if (st->k >= denom)  st->obs = HET_OBS_ALWAYS;
    else                      st->obs = HET_OBS_SOMETIMES;
  }

  /* ---- 3. The corroboration tier.  Distinct RUNS, not merely distinct cells:
     runs are re-seeded and carry a fresh phase/thermal draw. */
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

/* The machine-readable line.  hetlitmus/campaign.py schedules from it. */
static void het_stats_line(FILE *_ch, const het_stats_t *_s) {
  fprintf(_ch,
    "HetStats %s cpu_only=%d obs=%s "
    "R=%d usable=%d k=%d k_eff=%d k_runs=%d degen=%d first_sight=%d "
    "sighting=%s N=%llu scored=%llu discarded=%llu flags=0x%x\n",
    _s->test_name ? _s->test_name : "(none)",
    _s->cpu_only,
    het_obs_class_name(_s->obs), _s->R, _s->R_usable, _s->k, _s->k_eff, _s->k_runs,
    _s->n_degen, _s->n_at_first_sight,
    het_sighting_name(_s->tier),
    (unsigned long long)_s->N, (unsigned long long)_s->iters_scored,
    (unsigned long long)_s->iters_discarded,
    _s->flags);
}

/* The human block: the interpretation travels with the number. */
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

  if (_s->obs == HET_OBS_VOID) {
    fprintf(_ch, "  VOID -- not one of the %d runs was usable (every cell COLD).  "
                 "There is nothing here to report: an empty histogram from a dead "
                 "harness is not a non-observation, it is an absence of data.  See "
                 "the per-run HetVerdict lines for which mechanism was dead.\n", _s->R);
    return;
  }

  /* ---- the headline, by observation class.  A null's two numbers come from two
     pools: the scoring statement is over the usable cells, the effort over the
     runs executed -- a discarded run still spent its iterations. */
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
      "  effort: %d run(s) x N=%llu iterations, %llu scored, %llu discarded at "
      "the rendezvous.  Grow R, NOT N.\n",
      _s->R_usable, _s->R, (unsigned long long)_s->N,
      (unsigned long long)_s->iters_scored,
      (unsigned long long)_s->iters_discarded);
    return;
  }

  /* ---- observed. */
  fprintf(_ch,
    "  OBSERVED in %d of %d run(s), %d of them after the decode guard.  The "
    "denominator is R, the runs EXECUTED: nothing co-runs to make \"usable\" "
    "outcome-independent, so scoring over usable cells alone would report ALWAYS "
    "for a row that fired in only some of them.  NO RATE IS ATTACHED to the "
    "count.\n",
    _s->k, _s->R, _s->k_eff);

  if (_s->flags & HET_ST_DEGEN_SIGHTING)
    fprintf(_ch,
      "  *** %d SIGHTING(S) CAME FROM A DEGENERATE CELL *** (nothing scored, or a "
      "readout that never varied).  Srivastava observed exactly this artefact -- "
      "a reader stuck on init or on one value yields a spurious 100%%/0%%.\n"
      "  They are REPORTED, not discarded: falsification is one-sided and a genuine "
      "sighting stands.  They just do not COUNT toward corroboration.\n",
      _s->n_degen);

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

/* The campaign stopping rule: one rule for every test, and a pure function of
 * the record stream, so the in-binary loop and hetlitmus/campaign.py apply the
 * SAME policy.  Which shape is stubborn is a property of the part, not of the
 * shape [Kirkham20 sec 4.2 Tab.6].
 * hetlitmus/docs/harness-reporting.md sec 5. */
typedef enum {
  HET_CAMPAIGN_CONTINUE = 0,
  HET_CAMPAIGN_STOP_CORROBORATED, /* sighting reproduced in HET_CORROB_RUNS runs  */
  HET_CAMPAIGN_STOP_UNCONFIRMED,  /* a LONE clean sighting the confirmation window
                                     closed on without corroborating it           */
  HET_CAMPAIGN_STOP_BUDGET        /* budget exhausted, with nothing to show        */
} het_campaign_stop_t;

/* hetlitmus/campaign.py reads these strings back out of its state file, so they
   are an interface and not a printout. */
static const char *het_campaign_stop_name(het_campaign_stop_t s) {
  switch (s) {
  case HET_CAMPAIGN_STOP_CORROBORATED: return "CORROBORATED";
  case HET_CAMPAIGN_STOP_UNCONFIRMED:  return "UNCONFIRMED-SIGHTING";
  case HET_CAMPAIGN_STOP_BUDGET:       return "BUDGET";
  default:                             return "CONTINUE";
  }
}

/* UNCONFIRMED-SIGHTING is the one stop whose name is not its meaning, so it is
   the one that carries a sentence. */
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
  /* A window shorter than one run is not a window. */
  if (confirm_runs < 1) confirm_runs = 1;
  /* k_eff counts sightings that PASSED the decode guard, so an artefact neither
     stops a row nor holds one open: a degenerate-only sighting leaves k_eff at 0
     and takes the null arm below (st.tier would not -- it is set by k). */
  if (st.k_eff > 0 && !rate_mode) {
    if (st.tier == HET_SIGHT_CORROBORATED) return HET_CAMPAIGN_STOP_CORROBORATED;
    /* The window elapses FROM the sighting: n_at_first_sight is one-based and > 0
       whenever k_eff > 0, so this is the runs spent since it.  Against n alone a
       row firing late would be banked with no runs to reproduce in. */
    if (n - st.n_at_first_sight >= confirm_runs)
      return HET_CAMPAIGN_STOP_UNCONFIRMED;
    return HET_CAMPAIGN_CONTINUE;               /* outranks the budget stop below */
  }
  if (budget > 0 && n >= budget) return HET_CAMPAIGN_STOP_BUDGET;
  return HET_CAMPAIGN_CONTINUE;
}

#endif /* HET_VERDICT_H */
