/* =========================================================================
 * het_verdict.h -- the observation record, the outcome rule and the campaign
 * aggregate.  Emitted verbatim into every harness dir: edit this file, not a
 * harness-dir copy.  A null reports the effort the run spent and the liveness
 * its own counters measured; the rule and the sentences it prints are
 * hetlitmus/docs/harness-reporting.md.
 * ========================================================================= */
#ifndef HET_VERDICT_H
#define HET_VERDICT_H

#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>   /* getenv: the run-time campaign knobs                 */
#include <string.h>   /* memset: het_stats_compute zeroes its own aggregate  */

/* Mechanism names, not part names; the pair is HET_PAIR_NAME
   (hetlitmus/docs/het-emission.md "The pair a harness names"). */
#define HET_LINK_NAME "host-device interconnect"  /* no leading article: sites add it */
#define HET_HOST_HALF "the host half"
#define HET_DEV_HALF "the device half"
/* Default when the dialect stamps no lever (same section). */
#ifndef HET_PLACE_LEVER
#define HET_PLACE_LEVER "the page-placement lever"
#endif

/* What this binary was built for; the emitter stamps it from every pair.  The
   default serves a standalone compile of this header. */
#ifndef HET_PAIR_NAME
#define HET_PAIR_NAME "(unstamped CPU ISA x GPU dialect pair)"
#endif

/* Cells (instance,run) the aggregate can hold.  A campaign with more runs is
   truncated and flags HET_ST_CELLS_TRUNCATED rather than silently scoring a
   subset. */
#ifndef HET_STATS_MAX_CELLS
#define HET_STATS_MAX_CELLS 128
#endif

/* Share of N the rendezvous may discard before the run itself is discarded:
   past it the two sides mostly did not run together, so the iterations that
   did are not a sample of the window the test is about.  het_rdv.h's caps
   produce the discards; this is the budget the rule spends. */
#ifndef HET_RDV_MAX_DISCARD_PCT
#define HET_RDV_MAX_DISCARD_PCT 50
#endif

/* Which stress mechanisms this build asked for: a zero tally is dead only where
   the mechanism was requested, or a no-stress baseline would be COLD forever.
   Bit numbers are a wire format, vacancies (1) included: add at the top, do not
   renumber (hetlitmus/docs/harness-reporting.md sec 7). */
#define HET_REQ_GPU_STRESS  (1u << 0)   /* HET_PRE_STRESS_PCT | HET_MEM_STRESS_PCT */
#define HET_REQ_CPU_ENEMY   (1u << 2)   /* HET_CPU_ENEMIES                         */
#define HET_REQ_CPU_PRELOAD (1u << 3)   /* HET_CPU_PRELOAD_PCT && _PRELOAD_LIVE    */
#define HET_REQ_NOISE_CPU   (1u << 4)   /* HET_NOISE_CPU                           */
#define HET_REQ_NOISE_GPU   (1u << 5)   /* HET_NOISE_GPU_BLOCKS                    */

typedef struct het_obs_record {
  const char *test_name; int instance_id; int run_id;
  /* 1 when every proc of this test is a CPU proc: no cross-device path carries
     the cycle, and the printout says so. */
  int cpu_only;
  /* GPU test lanes in this build.  At 0 the stress round loop exits before its
     body runs once, so the mechanism is structurally absent; that caveat is
     keyed here and NOT on cpu_only, which is a property of the cycle. */
  int gpu_lanes;
  uint64_t N;
  /* One iteration scores one outcome vector, so target_count <= iters_scored
     <= N, and discarded (a participant did not start it) + scored = N once the
     readout ran. */
  uint64_t iters_scored;
  uint64_t iters_discarded;
  uint64_t target_count;
  /* rdv_valid says the readout ran, separating the counts above from memset
     zeros.  rdv_cap_cpu / rdv_cap_gpu count cap expiries per participant per
     iteration, so they neither partition nor bound iters_discarded.  cap_cpu /
     cap_gpu are the waits this run used; cap_calibrated is 0 until they are
     measured on the target. */
  int rdv_valid;
  uint64_t rdv_cap_cpu, rdv_cap_gpu;
  uint32_t cap_cpu, cap_gpu;
  int cap_calibrated;
  /* 0 = every scored iteration read back the same outcome vector, the
     constant-read artefact [Srivastava24 sec 4.1]: a caveat, not a discard. */
  int outcomes_vary;
  /* GPU stress liveness, the only run-time evidence the layer ran (it leaves no
     trace in the tested op stream).  stress_truncated: lanes that stopped
     stressing while the test still ran.  gpu_stress_rounds: max rounds one
     het_do_stress call completed; stress blocks fill what the co-residency cap
     leaves over the test lanes, so that cap squeezes them to zero first. */
  uint64_t stress_truncated;
  uint64_t gpu_stress_rounds;
  /* CPU + interconnect liveness, for the levers the GPU tallies do not cover.
     A zero rounds/ops field means the mechanism did not run; a nonzero
     *_failures field means a pin or a placement was refused, so the topology
     is not the one being tuned. */
  uint64_t cpu_enemy_rounds, cpu_enemy_accesses, cpu_preload_ops;
  uint64_t noise_cpu_rounds, noise_cpu_words;
  uint32_t noise_gpu_blocks, noise_gpu_rounds;
  uint32_t cpu_enemies, cpu_aff_failures, place_failures;
  /* What the run realised, not what it asked for: a noise working set below the
     last-level cache is served from cache and crosses nothing (HET_LLC_MB,
     het_cpu_stress.h). */
  uint32_t noise_ws_mb, place_mode;
  uint32_t stress_requested;    /* HET_REQ_* bitmask -- see above */
} het_obs_record;

/* ---------------------------------------------------------------------------
 * Run-time knobs, read with getenv rather than -D (nvcc folds a compile-time
 * knob and deletes the only branch with side effects); hetlitmus/campaign.py
 * retunes them per invocation without a rebuild, and unset means the compiled
 * default.
 *   HET_RUNS_MAX      runs this invocation, clamped to the compiled
 *                     NUMBER_OF_RUN; R grows by re-invoking with a fresh
 *                     HET_SEED
 *   HET_ADAPTIVE      1 => consult het_campaign_should_stop() after every run
 *   HET_RATE          1 => run to budget even after a sighting, for a rate
 *   HET_CONFIRM_RUNS  runs a lone clean sighting may hold the row open for,
 *                     counted from the run it fired in (default 30, floor 1)
 *   HET_SEED          the seed base; vary it per invocation, since a replayed
 *                     seed draws no fresh phase and pools as one draw twice
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
 * zero a datum at all.  A dead mechanism yields HET_COLD_INVALID, not "not
 * observed" (hetlitmus/docs/harness-reporting.md sec 2). */
typedef enum {
  HET_OBSERVED = 0,
  HET_NOT_OBSERVED,
  HET_COLD_INVALID
} het_verdict_t;

/* Why a run was DISQUALIFIED (its null is discarded): each names a mechanism
   that is dead, not merely suboptimal.  Vacant bits: 0, 1, 2, 4, 10, 11. */
#define HET_DQ_STRESS_TRUNCATED (1u << 3)  /* stress stopped mid-run              */
#define HET_DQ_CPU_ENEMY_DEAD   (1u << 5)
#define HET_DQ_CPU_PRELOAD_DEAD (1u << 6)
#define HET_DQ_NOISE_CPU_DEAD   (1u << 7)  /* NOT interconnect-stressed           */
#define HET_DQ_NOISE_GPU_DEAD   (1u << 8)
#define HET_DQ_GPU_STRESS_DEAD  (1u << 9)  /* het_do_stress requested, no round   */
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

/* The rule (hetlitmus/docs/harness-reporting.md sec 2): a pure function of the
   record. */
static het_verdict_t het_verdict(const het_obs_record *r,
                                 uint32_t *dq_out, uint32_t *cv_out) {
  uint32_t dq = 0, cv = 0;
  uint32_t req = r->stress_requested;
  het_verdict_t v;

  /* ---- 1. Caveats first, since a sighting needs them too: only the provenance
     travels, the outcome is unchanged. */
  if (r->iters_scored > 0 && !r->outcomes_vary)
                                    cv |= HET_CV_ONE_OUTCOME;
  if (!r->cap_calibrated)           cv |= HET_CV_RDV_UNCALIBRATED;
  if (r->cpu_aff_failures > 0)      cv |= HET_CV_AFF_FAILED;
  if (r->place_failures > 0)        cv |= HET_CV_PLACE_REFUSED;
  if (req == 0)                     cv |= HET_CV_UNSTRESSED;
  /* The emitter withholds HET_REQ_GPU_STRESS at 0 lanes, where the mechanism
     is unreachable rather than dead, so it is caveated here instead -- keyed
     on the lane count, NOT on cpu_only: a harness that merely forgot to
     request a reachable mechanism keeps its lane count and het_dead()
     disqualifies it. */
  if (r->gpu_lanes == 0)            cv |= HET_CV_NO_GPU_LANES;

  /* ---- 2. A sighting is believed unconditionally: an inert-stress run that
     saw the outcome still saw it. */
  if (r->target_count > 0) {
    if (dq_out) *dq_out = 0;
    if (cv_out) *cv_out = cv;
    return HET_OBSERVED;
  }

  /* ---- 3. Liveness: is this run's null a datum at all?  The partner's first,
     which no stress tally covers: a run whose iterations mostly ended at the
     cap has an empty histogram about the rendezvous, not the memory model. */
  if (!r->rdv_valid || r->iters_scored == 0 ||
      r->iters_discarded * 100 > r->N * HET_RDV_MAX_DISCARD_PCT)
                                                  dq |= HET_DQ_RDV_DEAD;
  if (r->stress_truncated > 0)                    dq |= HET_DQ_STRESS_TRUNCATED;
  /* het_stress.h's round tally says the loop ran; whether it still contains its
     scratchpad accesses is a static question, and neither answer subsumes the
     other. */
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

/* Every null prints beside the effort it cost and the liveness this run
   measured, in absolute numbers (hetlitmus/docs/harness-reporting.md sec 4). */

/* Provenance caveats, printed for a sighting and for a null alike. */
static void het_print_caveats(FILE *_ch, const het_obs_record *_r, uint32_t cv) {
  if (cv & HET_CV_UNSTRESSED)   /* [Kirkham20 sec 6.2 Tab.10] */
    fprintf(_ch, "  CAVEAT: no stress was requested; an unstressed null is "
                 "weak evidence.\n");
  if (cv & HET_CV_ONE_OUTCOME)
    fprintf(_ch, "  CAVEAT: all %llu scored iteration(s) read back the SAME "
                 "outcome vector -- a reader stuck on one value -- so this run "
                 "measured one thing %llu times.\n",
            (unsigned long long)_r->iters_scored,
            (unsigned long long)_r->iters_scored);
  if (cv & HET_CV_RDV_UNCALIBRATED)
    fprintf(_ch, "  CAVEAT: the rendezvous caps are PLACEHOLDERS (cpu=%u, gpu=%u "
                 "polls), not a measurement on this target, so the %llu discarded "
                 "iteration(s) price an uncalibrated wait.\n",
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

  /* ---- The sighting, believed unconditionally. */
  if (v == HET_OBSERVED) {
    fprintf(_ch,
      "  ** %s: the weak outcome was OBSERVED in %llu of the %llu scored "
      "iteration(s) of N=%llu (%.4f%%).\n"
      "  Report it as what %s exhibited under this harness and this stress.\n",
      _r->test_name, _hits,
      (unsigned long long)_r->iters_scored, _n, _pct,
      HET_PAIR_NAME);
    if (_r->cpu_only) {   /* [APM Table 7-2] */
      fprintf(_ch,
        "  ** CPU-ONLY CYCLE: every proc of this test is a CPU proc, so no "
        "cross-device path carried it: what fired is the host ISA on the "
        "shared allocation, which rules a UC mapping out but does not "
        "establish WB over WC.\n");
    }
    het_print_config(_ch, _r);
    het_print_caveats(_ch, _r, cv);
    return;
  }

  /* ---- Not observed: the counts print first, under both null arms. */
  het_print_notobserved(_ch, _r);

  if (v == HET_COLD_INVALID) {
    fprintf(_ch, "  DISCARD this null -- the harness was not demonstrably hot:\n");
    if (dq & HET_DQ_RDV_DEAD)
      fprintf(_ch, "    - the RENDEZVOUS: %llu of N=%llu iteration(s) scored, "
                   "%llu discarded at the cap (caps %u/%u polls, budget "
                   "%d%%)%s; the cap expired %llu time(s) on a CPU participant "
                   "and %llu on a GPU lane, counted per participant per "
                   "iteration.  A timed-out rendezvous is a DEAD PARTNER or a "
                   "cap set too short, not a non-observation\n",
              (unsigned long long)_r->iters_scored,
              (unsigned long long)_r->N,
              (unsigned long long)_r->iters_discarded,
              _r->cap_cpu, _r->cap_gpu, (int)HET_RDV_MAX_DISCARD_PCT,
              _r->rdv_valid ? "" : " -- and the readout did not run at all",
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
      fprintf(_ch, "    - the GPU scratchpad stress (HET_PRE_STRESS_PCT/"
                   "HET_MEM_STRESS_PCT) was requested but completed ZERO "
                   "rounds\n");
    het_print_caveats(_ch, _r, cv);
    return;
  }

  /* ---- The null frame. */
  fprintf(_ch,
    "  NOT OBSERVED under this effort on %s; the counts above are this run's "
    "reach.\n",
    HET_PAIR_NAME);
  if (_r->cpu_only)   /* [APM Table 7-2] */
    fprintf(_ch,
      "  *** SHARED-ALLOCATION PROBE: this is a CPU-only shape, so a null here "
      "is about the memory type of the shared allocation, not about a "
      "cross-device window; it stays unresolved until the mapping is known to "
      "be WB (check PAT/MTRR and /proc/self/smaps for this allocator).\n");

  het_print_caveats(_ch, _r, cv);
}

/* The aggregate, a pure function of an array of het_obs_records, run host-side
 * after the campaign.  The iteration is not the trial: the replication unit is
 * the (instance,run) cell and Y = 1[target_count >= 1] is what is counted
 * (hetlitmus/docs/harness-reporting.md sec 5). */

/* What the campaign saw, at the (instance,run) unit. */
typedef enum {
  HET_OBS_VOID = 0,   /* not one usable cell: nothing here was measured           */
  HET_OBS_NEVER,      /* k = 0 usable cells observed it                            */
  HET_OBS_SOMETIMES,
  HET_OBS_ALWAYS
} het_obs_class;

/* Corroboration layers on top of het_verdict()'s HET_OBSERVED and suppresses
   nothing: HET_CORROB_RUNS is a bar in clean runs, not a confidence, since a
   constant-read artefact forges a sighting [Srivastava24 sec 4.1]. */
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
  int n_degen;        /* sightings the guard rejected (reported, not counted) */
  /* Distinct runs consumed when the first clean sighting landed; 0 = none did.
     The price of the sighting, in the unit the campaign spends. */
  int n_at_first_sight;

  uint64_t N, iters_scored, iters_discarded;   /* the effort disclosure          */
  uint32_t flags;
} het_stats_t;

/* The decode guard: could this cell's sighting be the constant-read artefact
   [Srivastava24 sec 4.1]?  A readout that did not run, a cell that scored
   nothing and one whose every iteration read back the same vector all fail
   closed.  The sighting is still reported; it does not count toward
   corroboration. */
static int het_cell_degenerate(const het_obs_record *r) {
  return !r->rdv_valid || (r->iters_scored == 0) || !r->outcomes_vary;
}

/* The aggregate: a pure function of the record stream. */
static void het_stats_compute(const het_obs_record *recs, int n, het_stats_t *st) {
  int    runs[HET_STATS_MAX_CELLS];
  int    allruns[HET_STATS_MAX_CELLS];
  int i, nruns = 0, nall = 0;

  memset(st, 0, sizeof *st);
  if (n <= 0) { st->obs = HET_OBS_VOID; return; }
  st->R         = n;
  st->test_name = recs[0].test_name;
  st->N         = recs[0].N;
  /* Cells that do not agree on cpu_only are not one campaign. */
  st->cpu_only  = recs[0].cpu_only;
  { int _i;
    for (_i = 1; _i < n; _i++)
      if (recs[_i].cpu_only != recs[0].cpu_only) {
        st->flags |= HET_ST_MIXED_POOL;
        /* cpu_only resolves upward: it names the narrower experiment, and a het
           reading must not absorb it silently. */
        if (recs[_i].cpu_only) st->cpu_only = 1;
      }
  }
  if (n > HET_STATS_MAX_CELLS) { n = HET_STATS_MAX_CELLS;
                                 st->flags |= HET_ST_CELLS_TRUNCATED; }

  /* ---- 1. The cells, scored through het_verdict() rather than by re-deriving
     liveness, so every stress disqualifier is inherited. */
  for (i = 0; i < n; i++) {
    het_verdict_t v = het_verdict(&recs[i], NULL, NULL);
    int y   = recs[i].target_count >= 1;
    int deg = het_cell_degenerate(&recs[i]);

    /* A sighting is not COLD, so this count discards none. */
    if (v != HET_COLD_INVALID) st->R_usable++;

    /* Runs consumed so far, over every cell and not only the sighting ones:
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

  /* ---- 2. The observation class.  The denominator is R, the runs executed: a
     cell is usable when it fired or when its own liveness counters were alive,
     so scoring over usable cells alone would report Always for a row that fired
     in 3 of 10.  Void alone turns on R_usable: such a pool measured nothing. */
  { int denom = st->R;
    if (st->R_usable == 0)    st->obs = HET_OBS_VOID;
    else if (st->k == 0)      st->obs = HET_OBS_NEVER;
    else if (st->k >= denom)  st->obs = HET_OBS_ALWAYS;
    else                      st->obs = HET_OBS_SOMETIMES;
  }

  /* ---- 3. The corroboration tier.  Distinct runs, not merely distinct cells:
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

/* The human block: the numbers, and the one instruction a reader acts on. */
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
    fprintf(_ch, "  VOID -- not one of the %d run(s) was usable (every cell "
                 "COLD): nothing was measured.  The per-run HetVerdict lines "
                 "name the dead mechanism.\n", _s->R);
    return;
  }

  /* ---- the headline, by observation class.  The scoring statement is over
     the usable cells, the effort over the runs executed: a discarded run still
     spent its iterations. */
  if (_s->obs == HET_OBS_NEVER) {
    fprintf(_ch,
      "  NOT OBSERVED in any of the %d usable cell(s).\n"
      "  effort: %d run(s) x N=%llu iterations, %llu scored, %llu discarded at "
      "the rendezvous.  Grow R, not N.\n",
      _s->R_usable, _s->R, (unsigned long long)_s->N,
      (unsigned long long)_s->iters_scored,
      (unsigned long long)_s->iters_discarded);
    return;
  }

  /* ---- observed. */
  fprintf(_ch,
    "  OBSERVED in %d of %d run(s), %d of them after the decode guard.\n",
    _s->k, _s->R, _s->k_eff);

  if (_s->flags & HET_ST_DEGEN_SIGHTING)
    fprintf(_ch,
      "  *** %d sighting(s) came from a DEGENERATE cell (nothing scored, or a "
      "readout that did not vary): reported, but not counted toward "
      "corroboration.\n",
      _s->n_degen);

  if (_s->tier != HET_SIGHT_NONE) {
    if (_s->tier == HET_SIGHT_CORROBORATED)
      fprintf(_ch,
        "  ** SIGHTING %s ** -- reproduced in %d distinct clean run(s) "
        "(>= HET_CORROB_RUNS = %d), which a constant-read artefact does not.  "
        "How often it reproduces is not reported.\n",
        het_sighting_name(_s->tier), _s->k_runs, (int)HET_CORROB_RUNS);
    else
      fprintf(_ch,
        "  ** SIGHTING %s ** -- seen in only %d clean run(s) "
        "(< HET_CORROB_RUNS = %d).  It stands as a sighting; reproduce it "
        "before it is written up.\n",
        het_sighting_name(_s->tier), _s->k_runs, (int)HET_CORROB_RUNS);
    if (_s->n_at_first_sight > 0)
      fprintf(_ch,
        "  It first fired after %d of the %d run(s) supplied: budget a fresh "
        "campaign for that; grow R, not N.\n",
        _s->n_at_first_sight, _s->R);
    if (_s->cpu_only)
      fprintf(_ch,
        "  ** CPU-ONLY CYCLE: every proc of this test is a CPU proc, so no "
        "cross-device path carried it: what fired is the host ISA on the "
        "shared allocation.\n");
  }
}

/* The campaign stopping rule: one rule for every test, and a pure function of
 * the record stream, so the in-binary loop and hetlitmus/campaign.py apply the
 * same policy.  Which shape is stubborn is a property of the part, not of the
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
  /* k_eff counts sightings that passed the decode guard, so an artefact neither
     stops a row nor holds one open: a degenerate-only sighting leaves k_eff at 0
     and takes the null arm below (st.tier would not -- it is set by k). */
  if (st.k_eff > 0 && !rate_mode) {
    if (st.tier == HET_SIGHT_CORROBORATED) return HET_CAMPAIGN_STOP_CORROBORATED;
    /* The window elapses from the sighting: n_at_first_sight is one-based and
       > 0 whenever k_eff > 0, so this is the runs spent since it.  Against n
       alone a row firing late would be banked with no runs to reproduce in. */
    if (n - st.n_at_first_sight >= confirm_runs)
      return HET_CAMPAIGN_STOP_UNCONFIRMED;
    return HET_CAMPAIGN_CONTINUE;               /* outranks the budget stop below */
  }
  if (budget > 0 && n >= budget) return HET_CAMPAIGN_STOP_BUDGET;
  return HET_CAMPAIGN_CONTINUE;
}

#endif /* HET_VERDICT_H */
