# Task 7 — AMD scoped axiomatic model: validation results

**Model:** `hetlitmus/cats/amd-gcn3.cat` (+ `hetlitmus/bells/ptx.bell`)
**Oracle:** `hetlitmus/tests/gpu-only/expected-amd-gcn3.csv` (PLDI'23 GCN3_X86)
**Runner:** `bash hetlitmus/cats/run-gpu-only.sh` (from repo root, herd7 in `_build/`)

## Result: 8 / 8 match

| test       | computed  | expected  | match |
|------------|-----------|-----------|-------|
| MP-sys     | Allowed   | Allowed   | OK    |
| MP-sys-F   | Forbidden | Forbidden | OK    |
| MP-cta-F   | Allowed   | Allowed   | OK    |
| LB-sys     | Forbidden | Forbidden | OK    |
| SB-sys     | Allowed   | Allowed   | OK    |
| SB-sys-F   | Forbidden | Forbidden | OK    |
| IRIW-sys   | Allowed   | Allowed   | OK    |
| IRIW-sys-F | Forbidden | Forbidden | OK    |

The three discriminating tests all pass: **MP-cta-F** Allowed (scope too narrow),
**SB-sys-F** and **IRIW-sys-F** Forbidden (system-scope rel/acq is strong).

> Verdict reading: herd7's line-1 `Test <name> Allowed` is the test *kind*, not the
> result. The result is the witness count for the `exists` (weak) outcome, on the
> `Observation <name> Never|Sometimes|Always` line. `Never` ⇒ weak outcome
> unreachable ⇒ **Forbidden**; `Sometimes`/`Always` ⇒ **Allowed**.

## How each verdict is produced (three axioms)

1. **`no-load-buffering`** — `acyclic (po & (R*W)) | rfe`. AMD GPU lanes preserve
   read→write program order; this breaks the LB cycle (LB-sys → Forbidden) without
   touching MP/SB/IRIW, whose cycles use W→W, R→R, or W→R program order, never R→W.
2. **`coherence`** — scoped release→acquire synchronisation (HRF `so`/hhb backbone):
   `so_S = ([REL & S] ; rfe ; [ACQ & S]) & tag2scope('S)` for S ∈ {cta,gpu,sys},
   `sw = so_cta|so_gpu|so_sys`, `hb = (po|sw)+`, `irreflexive (hb;fr)`. A release
   synchronises-with an acquire that reads it **iff they share a scope-instance at
   their annotated level** (read from the `scopes:` tree via `tag2scope`). MP-sys-F
   ⇒ Forbidden (one system instance); MP-cta-F ⇒ Allowed (its two threads are in
   distinct CTAs, so `tag2scope('cta)` does not relate them).
3. **`sys-strong`** — `acyclic ([strong];po;[strong]) | com`, `strong = (REL|ACQ) & SYS`.
   Models AMD system-scope rel/acq as a heavyweight flush+invalidate (store
   completion + multi-copy atomicity = SC among sys-scope atomics). This is the
   *only* thing that forbids SB-sys-F / IRIW-sys-F — their acquire loads read the
   initial value, so the rel→acq pairing of axiom 2 never fires (per
   hetlitmus/docs/gpu-only-corpus.md, "Why the synchronised verdicts hold").

## The D14 repair (2026-08-02) — three axioms became five, and 8/8 still holds

PORT2-R2 register item **D14** (`env-research/PORT2-R2-amd-oracle.md` §7) measured
three defects that had to be closed before this file could be cited as an
instrument by the AMD oracle derivation (archived on branch
`hetlitmus-oracle-derivation`), and none of them is visible to the 8-anchor
contract above:

| defect | symptom, measured | repair |
|---|---|---|
| no SC-per-location axiom | `coh-probe` (`W1 -rf-> R -po-> W2 -co-> W1`) → **Sometimes** | axiom **(0)** `acyclic po-loc \| com` ([HSA] Fig. 2-8 p.24), plus `irreflexive (hb;co)` beside the existing `irreflexive (hb;fr)` |
| fence blindness | deleting every `f[…]` from the 33 GPU-only fence tests changed **0/33** verdicts | axiom **(2)** gained [HSA] Fig. 3-15's two fence clauses; new axiom **(4)** is [SCATOM] Def. 27's `acy(SC² ∩ (Fsb?;(hb∪fr∪co);sbF?) ∩ incl)` |
| no `'sc` set | `2+2W-sys-release` **Never** vs `2+2W-sys-fence` **Sometimes** — a system `sc` fence read as strictly *weaker* than a system release store | `SCT = tag2events('sc)` folded into `REL`/`ACQ` ([SCATOM] Def. 10 p.637) |

**The contract still holds: 8/8.** It is also demonstrably blind — `tests/cram/amd-cat.t`
measures that **all eight** single-axiom ablations of this file still score 8/8 on the
anchor set. The artifact contains no fence and no `sc` operation at all, so the anchors
cannot test one line of axioms (0), (2)-fence or (4). What pins those is
`hetlitmus/cats/probes/` + the cram test, not the anchor run.

**What moved.** Over the 137-test GPU-only corpus, Forbidden went 18 → 30; against the
R2 generative rule, agreement went **107/137 → 117/137** at `M = GCN3-VIPER` and
**104/137 → 112/137** at `M = CDNA3`. Over a 6-shape × 5-primitive × 5-primitive
order-pair sweep at `sys` scope, Forbidden went **30/150 → 49/150** (25 of the
pre-repair 30 were the `LB` block, decided by axiom (1) whatever the primitives are).

**Two knowingly weaker readings were kept**, because "doubt resolves toward Allowed":
synchronisation is still built on `rfe` where [HSA] uses `coh`, and scope pairing is
still exact-match where [HSA] uses inclusion. A third: axiom (4) uses `(hb | fr | co)`
exactly as [SCATOM] Def. 27 prints it, not the transitive communication closure `coh`
that `env-research/g3-artifacts/amd-cdna3-candidate.cat` uses — `coh` would
additionally forbid the 8 cumulative rows `IRIW/RWC/WRC/WRC3-{gpu,sys}-fence`, which
need A-cumulativity of an `sc` fence that Def. 27 as printed does not supply.

## Two findings worth recording

- **`tag2set` is not a herd cat/Bell primitive.** The cat primitive to turn an
  annotation tag into an event set is **`tag2events('<tag>)`**; `tag2set` is
  interpreter-internal and unbound in both Bell and cat scope. `ptx.bell` had
  `let ACQ = tag2set('acquire)` …, which made the Bell fail to load
  (`unbound var: tag2set`); those convenience lines were removed from the Bell and
  the sets re-expressed with `tag2events` in the `.cat` (the only `ptx.bell` change).

- **diy could not emit a herd-parseable `scopes:` tree (two real tool bugs, now
  fixed).** herd builds scope-instance relations (`tag2scope`) only from a parseable
  `scopes: (sys (gpu (cta 0) …))` section in the `.litmus` body. diy could not
  produce that, for two independent reasons:
    1. **The dumper dropped it.** `diyone7` already builds the structured scope tree
       and hands it to the dumper (`gen/top_gen.ml` → `extra_data = [BellExtra …]`),
       but `lib/coreDumper.ml` `do_dump` printed info + init + prog + condition and
       *silently discarded* `extra_data`. Fix: emit the tree (via the existing
       `BellInfo.pp`) before the condition; guarded, so it is inert for tests with no
       scope tree. This restores round-trip symmetry — herd's parser already *reads*
       `scopes:`, now the dumper *writes* it.
    2. **The literal `-scopes "(tree)"` path was broken.** `lib/scopeParser.mly`
       requires `main: top_scope_tree EOF`, but `lib/scopeLexer.mll` had **no `eof`
       rule**, so at end of input it fell through to the error case → *"Lex error
       Scope lexer"*. Any nested literal tree failed. Fix: add `| eof { EOF }`.

  With both fixed, `generate.sh` passes each test its full tree via
  `diyone7 -scopes "(sys (gpu (cta 0) (cta 1) …))"` and diy writes the `scopes:`
  line itself — **no shell post-processing.** All three levels are present so
  `tag2scope('cta|'gpu|'sys)` resolve in every test, and the model reads
  scope-instance structure via `tag2scope` — no annotation shortcut, no assumption.

## Scope strength is read, not assumed (generalises to same-CTA tests)

The earlier draft of this model leaned on a corpus invariant ("cta-scope threads
sit in distinct CTAs"), which would have mis-modelled a cta-scope test whose two
threads share one CTA. That assumption is **removed**. With the real tree +
`tag2scope`, scope strength is read from the test:

| variant                              | `scopes:` tree                  | verdict   |
|--------------------------------------|---------------------------------|-----------|
| MP-cta-F (corpus): P0,P1 distinct CTAs | `(sys (gpu (cta 0) (cta 1)))`   | Allowed   |
| same test, P0,P1 in ONE CTA          | `(sys (gpu (cta 0 1)))`          | Forbidden |

Both come from the *same* `amd-gcn3.cat` with no edits — `tag2scope('cta)` relates
the two events in the second case (cta-scope sync fires) but not the first. This
is the behaviour required before cross-device / compound tests, where scope-instance
structure genuinely varies test-to-test.
