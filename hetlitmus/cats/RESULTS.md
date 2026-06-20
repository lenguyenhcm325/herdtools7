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
   `sw = [REL & WIDE] ; rfe ; [ACQ & WIDE]`, `hb = (po|sw)+`, `irreflexive (hb;fr)`.
   A sys-scope release synchronises-with the acquire that reads it ⇒ MP-sys-F
   Forbidden; a cta-scope release/acquire is too narrow to cross threads (cta ∉
   WIDE) ⇒ MP-cta-F stays Allowed.
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
  section in the `.litmus` body. The diy-generated corpus encodes its scope
  structure in a `Scopes=(sys 0 1)` **info field**, which herd does **not** parse —
  `tag2scope('sys)` raises *"cannot find scope instance sys"*. Since we are
  constrained not to edit the `.litmus` corpus, this model reads scope from the
  per-access **annotation** (`tag2events('cta|'gpu|'sys)`), which herd *does* parse,
  and encodes the hierarchy's meaning in the `.cat`.

  Consequence / limitation: the `WIDE = SYS | GPU` set bakes in the corpus
  invariant that cta-scope accesses sit in *distinct* CTAs (the MP-cta-F setup), so
  cta-scope rel/acq never synchronises cross-thread. This is correct for the entire
  GPU-only corpus but would mis-model a hypothetical cta-scope test whose two
  threads share one CTA (should synchronise). The general fix is to emit a real
  `scopes:` tree (teach `generate.sh`/the emitter to append it) and switch `sw`'s
  scope test to `tag2scope`. That is the right next step for cross-device (compound)
  tests where scope-instance structure actually varies.
