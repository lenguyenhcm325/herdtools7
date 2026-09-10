/* het_verdict.h -- the observation record, the outcome rule and the campaign
   aggregate.  Emitted verbatim into every harness dir: edit this file, not a
   copy (hetlitmus/docs/00-environment-design.md "Reporting"). */
#ifndef HET_VERDICT_H
#define HET_VERDICT_H

#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>   /* getenv: the run-time knobs */
#include <string.h>   /* memset                     */

/* The CPU ISA x GPU dialect the emitter stamps; the default serves a
   standalone compile. */
#ifndef HET_PAIR_NAME
#define HET_PAIR_NAME "(unstamped CPU ISA x GPU dialect pair)"
#endif

/* Share of N the rendezvous may discard before the run itself is discarded:
   past it the two sides mostly did not run together. */
#ifndef HET_RDV_MAX_DISCARD_PCT
#define HET_RDV_MAX_DISCARD_PCT 50
#endif

/* Which stress mechanisms this build asked for: a zero tally is dead only where
   requested.  Bits are a wire format: add at the top, never renumber
   (hetlitmus/docs/00-environment-design.md "Wire format"). */
#define HET_REQ_GPU_STRESS  (1u << 0)   /* HET_GPU_PRE_STRESS_PCT | HET_GPU_MEM_STRESS_PCT */
#define HET_REQ_CPU_STRESS  (1u << 2)   /* HET_CPU_STRESS_THREADS                  */
#define HET_REQ_CPU_PRELOAD (1u << 3)   /* HET_CPU_PRELOAD_PCT && _PRELOAD_LIVE    */
#define HET_REQ_CPU_NOISE   (1u << 4)   /* HET_CPU_NOISE_THREADS > 0               */
#define HET_REQ_GPU_NOISE   (1u << 5)   /* HET_GPU_NOISE_BLOCKS                    */

typedef struct het_obs_record {
  const char *test_name; int run_id;
  uint64_t N;
  /* target_count <= iters_scored <= N; discarded + scored = N once the readout
     ran. */
  uint64_t iters_scored;
  uint64_t iters_discarded;
  uint64_t target_count;
  /* rdv_valid: the readout ran, else the counts are memset zeros.  rdv_cap_*:
     cap expiries per participant per iteration, neither partitioning nor
     bounding iters_discarded.  cap_calibrated: 0 until cap_* are measured. */
  int rdv_valid;
  uint64_t rdv_cap_cpu, rdv_cap_gpu;
  uint32_t cap_cpu, cap_gpu;
  int cap_calibrated;
  /* 0 = one outcome vector across every scored iteration
     [Srivastava24 sec 4.1]: a caveat, not a discard. */
  int outcomes_vary;
  /* GPU stress liveness, the layer's only run-time trace.  stress_truncated:
     blocks that stopped while the test still ran; gpu_stress_rounds: max rounds
     one het_do_stress call completed (the co-residency cap squeezes them
     first). */
  uint64_t stress_truncated;
  uint64_t gpu_stress_rounds;
  /* CPU + interconnect liveness: zero rounds/ops = the mechanism did not run;
     cpu_aff_failures > 0 = a pin was refused. */
  uint64_t cpu_stress_rounds, cpu_stress_accesses, cpu_preload_ops;
  uint64_t cpu_noise_rounds, cpu_noise_words;
  uint32_t gpu_noise_blocks, gpu_noise_rounds;
  uint32_t cpu_stress_threads, cpu_aff_failures;
  /* Realised, not requested: a working set below the last-level cache stresses
     nothing (HET_LLC_MB, het_cpu_stress.h). */
  uint32_t noise_ws_mb;
  uint32_t stress_requested;    /* HET_REQ_* bitmask */
} het_obs_record;

/* Run-time knobs, read with getenv rather than -D (nvcc folds a compile-time
 * knob and deletes the only branch with side effects); unset = the compiled
 * default.
 *   HET_RUNS_MAX          runs this invocation, clamped to NUMBER_OF_RUN
 *   HET_STOP_AT_SIGHTING  1 => the run loop ends at the first clean sighting
 *   HET_SEED              seed base, varied per invocation (a replayed seed
 *                         adds no draw); unset or unparsable => entropy,
 *                         printed */
static long het_env_long(const char *name, long dflt) {
  const char *v = getenv(name);
  char *end;
  long x;
  if (v == NULL || *v == '\0') return dflt;
  x = strtol(v, &end, 0);
  return (end == v) ? dflt : x;
}

/* Was the weak outcome seen, and if not, is this run's zero a datum at all
 * (hetlitmus/docs/00-environment-design.md "Liveness"). */
typedef enum {
  HET_OBSERVED = 0,
  HET_NOT_OBSERVED,
  HET_COLD_INVALID
} het_verdict_t;

/* Why a run was DISQUALIFIED: a dead mechanism.
   Vacant bits: 0, 1, 2, 4, 10, 11. */
#define HET_DQ_STRESS_TRUNCATED (1u << 3)  /* stress stopped mid-run              */
#define HET_DQ_CPU_STRESS_DEAD  (1u << 5)
#define HET_DQ_CPU_PRELOAD_DEAD (1u << 6)
#define HET_DQ_CPU_NOISE_DEAD   (1u << 7)  /* NOT interconnect-stressed           */
#define HET_DQ_GPU_NOISE_DEAD   (1u << 8)
#define HET_DQ_GPU_STRESS_DEAD  (1u << 9)  /* het_do_stress requested, no round   */
/* No readout, nothing scored, or discards past HET_RDV_MAX_DISCARD_PCT of N. */
#define HET_DQ_RDV_DEAD         (1u << 12)

/* Why a null was CAVEATED (reportable, but weaker).
   Vacant bits: 0, 1, 2, 4, 5, 7. */
#define HET_CV_AFF_FAILED       (1u << 3)  /* a sched_setaffinity call failed     */
#define HET_CV_UNSTRESSED       (1u << 6)  /* no stress requested at all          */
#define HET_CV_ONE_OUTCOME      (1u << 8)  /* one outcome vector throughout   */
#define HET_CV_RDV_UNCALIBRATED (1u << 9)  /* het_rdv.h's placeholder caps    */

static int het_dead(uint32_t req, uint32_t bit, uint64_t rounds) {
  return (req & bit) && rounds == 0;
}

/* The rule, a pure function of the record. */
static het_verdict_t het_verdict(const het_obs_record *r,
                                 uint32_t *dq_out, uint32_t *cv_out) {
  uint32_t dq = 0, cv = 0;
  uint32_t req = r->stress_requested;
  het_verdict_t v;

  /* ---- 1. Caveats first: a sighting carries them too. */
  if (r->iters_scored > 0 && !r->outcomes_vary)
                                    cv |= HET_CV_ONE_OUTCOME;
  if (!r->cap_calibrated)           cv |= HET_CV_RDV_UNCALIBRATED;
  if (r->cpu_aff_failures > 0)      cv |= HET_CV_AFF_FAILED;
  if (req == 0)                     cv |= HET_CV_UNSTRESSED;

  /* ---- 2. A sighting is believed unconditionally. */
  if (r->target_count > 0) {
    if (dq_out) *dq_out = 0;
    if (cv_out) *cv_out = cv;
    return HET_OBSERVED;
  }

  /* ---- 3. Liveness: the partner first, which no stress tally covers. */
  if (!r->rdv_valid || r->iters_scored == 0 ||
      r->iters_discarded * 100 > r->N * HET_RDV_MAX_DISCARD_PCT)
                                                  dq |= HET_DQ_RDV_DEAD;
  if (r->stress_truncated > 0)                    dq |= HET_DQ_STRESS_TRUNCATED;
  /* The round tally says the loop ran, not that it still contains its
     scratchpad accesses. */
  if (het_dead(req, HET_REQ_GPU_STRESS,  r->gpu_stress_rounds))
                                                  dq |= HET_DQ_GPU_STRESS_DEAD;
  if (het_dead(req, HET_REQ_CPU_STRESS,  r->cpu_stress_rounds))
                                                  dq |= HET_DQ_CPU_STRESS_DEAD;
  if (het_dead(req, HET_REQ_CPU_PRELOAD, r->cpu_preload_ops))
                                                  dq |= HET_DQ_CPU_PRELOAD_DEAD;
  if (het_dead(req, HET_REQ_CPU_NOISE,   r->cpu_noise_rounds))
                                                  dq |= HET_DQ_CPU_NOISE_DEAD;
  if (het_dead(req, HET_REQ_GPU_NOISE,   (uint64_t)r->gpu_noise_blocks))
                                                  dq |= HET_DQ_GPU_NOISE_DEAD;

  /* ---- 4. A dead mechanism: this run's zero is not a datum. */
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
    "HetObs %s run=%d N=%llu scored=%llu discarded=%llu target=%llu "
    "cap_cpu=%llu/%u cap_gpu=%llu/%u calibrated=%d vary=%d "
    "stress_trunc=%llu do_stress_rounds=%llu req=0x%x "
    "stress_threads=%u stress_rounds=%llu stress_acc=%llu preload=%llu "
    "cpu_noise=%llu/%lluw gpu_noise=%u/%u noise_ws=%uMB aff_fail=%u\n",
    _r->test_name,
    _r->run_id,
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
    _r->cpu_stress_threads,
    (unsigned long long)_r->cpu_stress_rounds,
    (unsigned long long)_r->cpu_stress_accesses,
    (unsigned long long)_r->cpu_preload_ops,
    (unsigned long long)_r->cpu_noise_rounds,
    (unsigned long long)_r->cpu_noise_words,
    _r->gpu_noise_blocks, _r->gpu_noise_rounds,
    _r->noise_ws_mb, _r->cpu_aff_failures);
}

/* Caveats, printed for a sighting and for a null alike. */
static void het_print_caveats(FILE *_ch, const het_obs_record *_r, uint32_t cv) {
  if (cv & HET_CV_UNSTRESSED)   /* [Kirkham20 sec 6.2 Tab.10] */
    fprintf(_ch, "  CAVEAT: no stress was requested; an unstressed null is "
                 "weak evidence.\n");
  if (cv & HET_CV_ONE_OUTCOME)
    fprintf(_ch, "  CAVEAT: all %llu scored iteration(s) read back the SAME "
                 "outcome vector -- a reader stuck on one value.\n",
            (unsigned long long)_r->iters_scored);
  if (cv & HET_CV_RDV_UNCALIBRATED)
    fprintf(_ch, "  CAVEAT: the rendezvous caps are PLACEHOLDERS (cpu=%u, gpu=%u "
                 "polls), not measured on this target, so too short a cap may "
                 "explain the %llu discarded iteration(s).\n",
            _r->cap_cpu, _r->cap_gpu,
            (unsigned long long)_r->iters_discarded);
  if (cv & HET_CV_AFF_FAILED)
    fprintf(_ch, "  CAVEAT: %u sched_setaffinity call(s) FAILED -- those "
                 "threads ran wherever the scheduler put them.\n",
            _r->cpu_aff_failures);
}

/* Printed under every null, of either class. */
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

  fprintf(_ch, "HetVerdict %s run=%d: %s\n",
          _r->test_name, _r->run_id, het_verdict_name(v));

  /* ---- The sighting. */
  if (v == HET_OBSERVED) {
    fprintf(_ch,
      "  ** %s: the weak outcome was OBSERVED on %s in %llu of the %llu scored "
      "iteration(s) of N=%llu (%.4f%%).\n",
      _r->test_name, HET_PAIR_NAME, _hits,
      (unsigned long long)_r->iters_scored, _n, _pct);
    het_print_caveats(_ch, _r, cv);
    return;
  }

  /* ---- Both null arms: the counts first. */
  het_print_notobserved(_ch, _r);

  if (v == HET_COLD_INVALID) {
    fprintf(_ch, "  DISCARD this null -- the harness was not demonstrably hot:\n");
    if (dq & HET_DQ_RDV_DEAD)
      fprintf(_ch, "    - the RENDEZVOUS: %llu of N=%llu discarded at the cap "
                   "(budget %d%%)%s.  A timed-out rendezvous is a DEAD PARTNER "
                   "or a short cap, not a non-observation\n",
              (unsigned long long)_r->iters_discarded,
              (unsigned long long)_r->N,
              (int)HET_RDV_MAX_DISCARD_PCT,
              _r->rdv_valid ? "" : " -- the readout did not run");
    if (dq & HET_DQ_STRESS_TRUNCATED)
      fprintf(_ch, "    - stress_truncated=%llu: stress STOPPED while tested "
                   "lanes were still running\n",
              (unsigned long long)_r->stress_truncated);
    if (dq & HET_DQ_CPU_STRESS_DEAD)
      fprintf(_ch, "    - the CPU stress threads were requested but completed ZERO rounds\n");
    if (dq & HET_DQ_CPU_PRELOAD_DEAD)
      fprintf(_ch, "    - the cache preload was requested but issued ZERO hints\n");
    if (dq & HET_DQ_CPU_NOISE_DEAD)
      fprintf(_ch, "    - the host half of the host-device interconnect noise "
                   "completed %llu round(s): not interconnect-stressed\n",
              (unsigned long long)_r->cpu_noise_rounds);
    if (dq & HET_DQ_GPU_NOISE_DEAD)
      fprintf(_ch, "    - the device half of the host-device interconnect noise "
                   "ran in %u block(s): not interconnect-stressed\n",
              _r->gpu_noise_blocks);
    if (dq & HET_DQ_GPU_STRESS_DEAD)
      fprintf(_ch, "    - the GPU scratchpad stress was requested but "
                   "completed ZERO rounds\n");
    het_print_caveats(_ch, _r, cv);
    return;
  }

  /* ---- The null frame. */
  fprintf(_ch,
    "  NOT OBSERVED under this effort on %s; the counts above are this run's "
    "reach.\n",
    HET_PAIR_NAME);
  het_print_caveats(_ch, _r, cv);
}

/* The aggregate, host-side after the campaign; the run is the replication unit
 * (hetlitmus/docs/00-environment-design.md "Aggregate"). */

/* What the campaign saw, per run. */
typedef enum {
  HET_OBS_VOID = 0,   /* no usable run: nothing was measured */
  HET_OBS_NEVER,      /* k = 0                                */
  HET_OBS_SOMETIMES,
  HET_OBS_ALWAYS
} het_obs_class;

typedef struct het_stats {
  const char *test_name;
  het_obs_class obs;

  int R;              /* runs supplied (= NUMBER_OF_RUN)                  */
  int R_usable;       /* runs whose het_verdict() is not COLD-INVALID     */
  int k;              /* runs with target_count >= 1                      */
  int k_eff;          /* ... of those, the ones past the decode guard     */
  int n_degen;        /* sightings the guard rejected (reported, not counted) */

  uint64_t N, iters_scored, iters_discarded;   /* the effort disclosure  */
} het_stats_t;

/* The decode guard [Srivastava24 sec 4.1]: no readout, nothing scored or one
   vector throughout fails closed; the sighting still prints, outside k_eff. */
static int het_run_degenerate(const het_obs_record *r) {
  return !r->rdv_valid || (r->iters_scored == 0) || !r->outcomes_vary;
}

/* The aggregate: a pure function of the record stream. */
static void het_stats_compute(const het_obs_record *recs, int n, het_stats_t *st) {
  int i;

  memset(st, 0, sizeof *st);
  if (n <= 0) { st->obs = HET_OBS_VOID; return; }
  st->R         = n;
  st->test_name = recs[0].test_name;
  st->N         = recs[0].N;

  /* ---- 1. Each run through het_verdict(): every disqualifier is inherited. */
  for (i = 0; i < n; i++) {
    het_verdict_t v = het_verdict(&recs[i], NULL, NULL);
    int y   = recs[i].target_count >= 1;
    int deg = het_run_degenerate(&recs[i]);

    /* A sighting is not COLD, so this count discards none. */
    if (v != HET_COLD_INVALID) st->R_usable++;

    if (y) {
      st->k++;
      if (deg) st->n_degen++;
      else st->k_eff++;
    }

    st->iters_scored += recs[i].iters_scored;
    st->iters_discarded += recs[i].iters_discarded;
  }

  /* ---- 2. The class, over R rather than R_usable
     (hetlitmus/docs/00-environment-design.md "Aggregate"); Void alone turns on
     R_usable. */
  { int denom = st->R;
    if (st->R_usable == 0)    st->obs = HET_OBS_VOID;
    else if (st->k == 0)      st->obs = HET_OBS_NEVER;
    else if (st->k >= denom)  st->obs = HET_OBS_ALWAYS;
    else                      st->obs = HET_OBS_SOMETIMES;
  }
}

static const char *het_obs_class_name(het_obs_class c) {
  switch (c) {
  case HET_OBS_NEVER:     return "Never";
  case HET_OBS_SOMETIMES: return "Sometimes";
  case HET_OBS_ALWAYS:    return "Always";
  default:                return "VOID";
  }
}

/* The machine-readable line.  hetlitmus/campaign.py schedules from it. */
static void het_stats_line(FILE *_ch, const het_stats_t *_s) {
  fprintf(_ch,
    "HetStats %s obs=%s "
    "R=%d usable=%d k=%d k_eff=%d degen=%d "
    "N=%llu scored=%llu discarded=%llu\n",
    _s->test_name ? _s->test_name : "(none)",
    het_obs_class_name(_s->obs), _s->R, _s->R_usable, _s->k, _s->k_eff,
    _s->n_degen,
    (unsigned long long)_s->N, (unsigned long long)_s->iters_scored,
    (unsigned long long)_s->iters_discarded);
}

/* The human block. */
static void het_stats_print(FILE *_ch, const het_stats_t *_s) {
  het_stats_line(_ch, _s);

  fprintf(_ch, "HetStats %s: %d run(s), %d usable, observed in %d "
               "(%d after the decode guard).\n",
          _s->test_name ? _s->test_name : "(none)",
          _s->R, _s->R_usable, _s->k, _s->k_eff);

  if (_s->obs == HET_OBS_VOID) {
    fprintf(_ch, "  VOID -- not one of the %d run(s) was usable: nothing was "
                 "measured; the per-run HetVerdict lines name the dead "
                 "mechanism.\n", _s->R);
    return;
  }

  /* ---- the headline: scoring over the usable runs, effort over all runs. */
  if (_s->obs == HET_OBS_NEVER) {
    fprintf(_ch,
      "  NOT OBSERVED in any of the %d usable run(s).\n"
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

  if (_s->n_degen > 0)
    fprintf(_ch,
      "  *** %d sighting(s) came from a DEGENERATE run (nothing scored, or a "
      "constant readout): reported, not counted in k_eff.\n",
      _s->n_degen);
}

#endif /* HET_VERDICT_H */
