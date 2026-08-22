/* =========================================================================
 * obs-stats-driver.c -- the generator of hetlitmus/tests/cram/obs-stats.txt,
 * the synthetic log oracle-negatives.t's STATISTICS section runs on.
 *
 * It drives het_verdict.h's OWN printers over five synthetic record streams,
 * so the fixture cannot drift from the printers in wording while still
 * parsing.  The fixture's header, printed below, carries the command that
 * rebuilds it; that header is printed from here too, so obs-stats.txt is
 * reproducible from this repository alone.
 *
 * Edit with obs-stats.txt, oracle-stats.csv and oracle-negatives.t, never
 * alone: the row names are stamped into every block the section reprints.
 * ========================================================================= */
#include "het_verdict.h"

/* One row of the fixture: a test name, how many runs it ran, and how many of
   them (from run 0) saw the outcome.  `live' 0 makes every run COLD by the one
   disqualifier that needs no stress knob -- the two engines never overlapped. */
typedef struct {
  const char *name;
  int runs;
  int hits;
  int live;
} row_t;

#define MAX_RUNS 16               /* every row's `runs' has to fit this array */

static const row_t ROWS[] = {
  { "SB-sys",    6, 3, 1 },   /* a corroborated sighting: 3 clean runs        */
  { "MP-sys-F",  6, 1, 1 },   /* a lone sighting, unconfirmed                 */
  { "SB-sys-2s", 8, 0, 1 },   /* a null over 8 runs                           */
  { "MP-sys-2s", 2, 0, 1 },   /* the low-effort NEVER, over 2                 */
  { "LB-sys",    4, 0, 0 },   /* every run COLD: VOID, and nothing to report  */
};

static const char *HEADER[] = {
"# Synthetic log fixture for oracle-compare.sh's STATISTICS section (Layer-1 cram).",
"# Five tests, one per reporting path: a sighting corroborated across three clean",
"# runs; a lone sighting the corroboration bar rejects; a null over eight runs; the",
"# same null shape over only two (the low-effort NEVER, and the row that shows",
"# effort is disclosed rather than priced); and a row whose every cell was COLD",
"# (VOID).",
"# The HetObs / HetVerdict / HetStats lines are PRINTED BY het_verdict.h's own",
"# printers -- het_obs_record_print, het_verdict_print, het_stats_print -- over the",
"# record streams hetlitmus/tests/cram/obs-stats-driver.c builds.  They have to be",
"# the real thing: oracle-compare.sh reprints het_stats_print's block instead of",
"# re-deriving it.  NEVER HAND-EDIT A LINE BELOW; regenerate.",
"#",
"# REGENERATION, from the repo root.  This header is printed by the driver too, so",
"# the file is reproducible from this repository alone:",
"#   d=$(mktemp -d)",
"#   litmus7 -set-libdir litmus/libdir -gpu-target cuda -o \"$d\" \\",
"#           hetlitmus/tests/het/MP-cg-sys-fence-2s.litmus",
"#   h=\"$d/MP-cg-sys-fence-2s\"          # any het emission ships het_verdict.h",
"#   gcc -std=c99 -O2 -Wall -Wno-unused-function -I \"$h\" \\",
"#       hetlitmus/tests/cram/obs-stats-driver.c -o \"$d/drv\" -lm",
"#   \"$d/drv\" > hetlitmus/tests/cram/obs-stats.txt",
"#",
"# KNOWN GAP: no gate binds this text to the printers.",
};

/* The record every row is built from: one perpetual het run whose every
   requested mechanism is measured alive, seeing nothing.  The two decode
   channels are both tagged and the two lane counts are both nonzero, which is
   the two-engine harness with a reader that this fixture stands for. */
static het_obs_record base_record(const row_t *r, int run) {
  het_obs_record rec;
  memset(&rec, 0, sizeof rec);
  rec.rec_magic = HET_REC_MAGIC;
  rec.test_name = r->name;
  rec.instance_id = 0;
  rec.run_id = run;
  rec.confidence = CONF_ROBUST;
  rec.reporting = CONF_ROBUST;
  rec.N = 100000;
  rec.frames_examined = 100000;
  rec.exhaustive_valid = 1;
  rec.interleavings_detected = r->live ? 4096 : 0;
  rec.distinct_decoded_iters = 64;
  rec.skew_min = -3; rec.skew_max = 3;
  rec.skew_mean = 0.200; rec.skew_stddev = 1.500;
  rec.sync_valid = 1;
  rec.obs_valid = 1;
  rec.gpu_lanes = 1;
  rec.spin_lanes = 1;
  rec.spin_rendezvous = 4096;
  rec.gpu_stress_rounds = 64;
  rec.stress_requested = 0x3f;
  rec.cpu_enemies = 4;
  rec.cpu_enemy_rounds = 5000;
  rec.cpu_enemy_accesses = 400000;
  rec.cpu_preload_ops = 250;
  rec.noise_cpu_rounds = 120;
  rec.noise_cpu_words = 1048576;
  rec.noise_gpu_blocks = 8;
  rec.noise_gpu_rounds = 64;
  rec.noise_ws_mb = 512;
  if (run < r->hits) {
    rec.target_count_exhaustive = 1;
    rec.target_count_heuristic = 1;
  }
  return rec;
}

int main(void) {
  size_t i;
  int run;
  for (i = 0; i < sizeof HEADER / sizeof HEADER[0]; i++)
    printf("%s\n", HEADER[i]);
  for (i = 0; i < sizeof ROWS / sizeof ROWS[0]; i++) {
    const row_t *r = &ROWS[i];
    het_obs_record recs[MAX_RUNS];
    het_stats_t st;
    const char *lit_class;
    if (r->runs > MAX_RUNS) return 2;
    for (run = 0; run < r->runs; run++) {
      recs[run] = base_record(r, run);
      het_obs_record_print(stdout, &recs[run]);
      het_verdict_print(stdout, &recs[run]);
    }
    het_stats_compute(recs, r->runs, &st);
    het_stats_print(stdout, &st);
    /* The four litmus scaffolding lines the harness prints after its own
       block: oracle-compare.sh reads the quantifier off Condition and the
       observation class off Observation, so a fixture without them exercises
       the statistics roll-up and nothing that feeds it. */
    printf("Test %s\n", r->name);
    printf("Histogram (1 states)\n");
    printf("Condition exists (1:r0=1 /\\ 1:r1=0) is validated\n");
    /* The observation class on THIS line is the litmus histogram's -- how many
       runs matched the condition -- and NOT het_stats_compute's, which knows
       about usable cells and prints VOID where litmus prints Never. */
    lit_class = (r->hits == 0) ? "Never"
              : (r->hits >= r->runs) ? "Always" : "Sometimes";
    printf("Observation %s %s %d 6000\n", r->name, lit_class, r->hits);
    printf("\n");
  }
  return 0;
}
