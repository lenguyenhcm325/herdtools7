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

## Two findings worth recording

- **`tag2set` is not a herd cat/Bell primitive.** The cat primitive to turn an
  annotation tag into an event set is **`tag2events('<tag>)`**; `tag2set` is
  interpreter-internal and unbound in both Bell and cat scope. `ptx.bell` had
  `let ACQ = tag2set('acquire)` …, which made the Bell fail to load
  (`unbound var: tag2set`); those convenience lines were removed from the Bell and
  the sets re-expressed with `tag2events` in the `.cat` (the only `ptx.bell` change).

- **`Scopes=(…)` info field ≠ herd's `scopes:` tree.** herd builds scope-instance
  relations (`tag2scope`) only from a parseable `scopes: (sys (gpu (cta P0) …))`
  section in the `.litmus` body. diy emits scope structure as a `Scopes=(sys 0 1)`
  **info field** only — `BellInfo.pp` (the body-`scopes:` printer) has *zero callers*
  in the dump path, so diy never writes a parseable tree and `tag2scope('sys)`
  raises *"cannot find scope instance sys"*. **Fixed at the generator:**
  `generate.sh` now appends the full 3-level tree `(sys (gpu (cta P0) (cta P1) …))`
  to each test (all levels present so `tag2scope('cta|'gpu|'sys)` resolve
  everywhere), and the model reads scope-instance structure via `tag2scope` — not
  from annotations and not from any baked-in assumption.

## Scope strength is read, not assumed (generalises to same-CTA tests)

The earlier draft of this model leaned on a corpus invariant ("cta-scope threads
sit in distinct CTAs"), which would have mis-modelled a cta-scope test whose two
threads share one CTA. That assumption is **removed**. With the real tree +
`tag2scope`, scope strength is read from the test:

| variant                              | `scopes:` tree                  | verdict   |
|--------------------------------------|---------------------------------|-----------|
| MP-cta-F (corpus): P0,P1 distinct CTAs | `(sys (gpu (cta P0) (cta P1)))`  | Allowed   |
| same test, P0,P1 in ONE CTA          | `(sys (gpu (cta P0 P1)))`        | Forbidden |

Both come from the *same* `amd-gcn3.cat` with no edits — `tag2scope('cta)` relates
the two events in the second case (cta-scope sync fires) but not the first. This
is the behaviour required before cross-device / compound tests, where scope-instance
structure genuinely varies test-to-test.
