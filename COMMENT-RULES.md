# HetLitmus code-comment rules

Scope: every HetLitmus-added line a human reads beside code — comments in
OCaml/C/CUDA/HIP/shell/Python, Python docstrings, cram `.t` prose, Makefile
target headers, `litmus/het-runtime/README.md` — and `hetlitmus/docs/`, the
home those sites point into. Upstream herdtools7 files keep upstream style.

A comment's job: state what the code cannot say about itself — the invariant,
the hazard, the non-local constraint — for a reader who has only this repo.
Everything else has a designated home: the commit message (history, incidents,
measurements), the gate script (verification story), `hetlitmus/docs/`
(design rationale), `hetlitmus/docs/REFERENCES.md` (external sources).

## What a comment may say

1. **Present, not process.** State the invariant as it is now. No dates, no
   dev-machine identifiers, no compiler/error transcripts, no before/after or
   "until/since/used to/superseded" phrasing. A past bug earns at most one
   present-tense hazard sentence ("a proc-keyed dict keeps only the last body;
   key by (proc, fname)"); the incident itself lives in the commit that fixed
   it. Target-hardware facts the code is *about* (gfx942, GH200) are product
   facts, not dev metadata — they stay.
2. **Keep the load-bearing lines:** non-local constraints, upstream-divergence
   facts, citation obligations, why-this-branch one-liners. One line means one
   line: a "why" that needs a second sentence is rationale and lives in docs
   (rule 7), the site keeping the pointer.
3. **No reviewer rhetoric.** Cut sentences arguing the change is correct,
   sound, complete, byte-identical, or disclosed. A divergence from a cited
   source = one sentence + key.
4. **Research provenance is not content.** "Web-fetched", "grounded against",
   "measured, not assumed", "confirmed by" never appear. State the fact, cite
   the source.
5. **Code never mentions its tests; tests do not narrate the design.**
   Emitter/runtime source names no gate, cram file, check, planted
   counterfactual or pinned byte — not even as a one-line marker. What a gate
   greps is the gate's knowledge, recorded in the gate; a construct it depends
   on is protected by the gate failing, not by a comment asking nobody to move
   it.
   Symmetrically, a gate docstring, a cram paragraph and a Makefile header say
   WHAT is pinned and what a miss means, never why the design is shaped as it
   is: a cram block gets one sentence naming the property, a gate docstring
   lists its checks, and the design is a pointer.
   Docs must not mention tests either: a `hetlitmus/docs/` file documents
   the mechanism and its rationale, never the gate, cram file or QA step that
   pins it. The verification story is the gate's own;
   `hetlitmus/docs/README-tests.md` is the one index of tests, and no other
   docs file names them.
6. **No free-prose inventory numbers.** Corpus/file/proc counts appear only as
   pinned constants cross-checked at runtime, never in prose ("33 of the 137")
   where they silently rot.

## Where everything else lives

7. **One home per idea, and rationale's home is `hetlitmus/docs/`.** A sentence
   saying why a mechanism is shaped as it is, what a source established, or
   what a number was sized against lives in the matching docs file and nowhere
   else; every other site gets one line + pointer
   (`hetlitmus/docs/00-environment-design.md sec 3.3`). The test: if the
   sentence could be pasted into a docs file unchanged, it belongs there. Never
   restate a caveat beside its pointer — if the pointer feels insufficient, fix
   the home, not the comment. A gate's contract lives in its script docstring,
   once; the Makefile target header gets ≤ 3 lines (what it proves, how to
   run, how to regenerate); `hetlitmus/docs/README-tests.md` points at the
   script, it does not re-describe it.
8. **Pointers resolve in-repo or in print.** Point only at (a) repo files or
   (b) `[Key]`s from REFERENCES.md. Never "memo N", plan files, or Claude
   memory/session artifacts. A fact whose only home is outside the repo
   moves into `hetlitmus/docs/` in the same change, then gets pointed at.
9. **Cite at the home, point from the site.** External sources appear as
   `[Key]` resolved in `hetlitmus/docs/REFERENCES.md`, which holds the full
   citation, the claim this project takes from it, and any deviation. The claim
   is *stated* once, in the docs file that rests on it; a code site carries the
   key only where that line is the claim's implementation (the instruction,
   the scope, the constant), as a bare `[Key locator]` with no restatement of
   what the source says. Add a locator when the source is long enough that the
   key alone doesn't land the reader on the claim: papers get fixed locators
   (`[Lustig19 §5.2]`, `Fig.10`, `Table 3`); living documents get the section
   *name*, whose anchors outlive renumbering (`[AMDGPUUsage "Memory
   Scopes"]`). Short sources (a review ID, a man page) need none. No quotes,
   no derivations at the site.
10. **Zero project codenames.** Tier-N, P2x, B*, DR*, F*, Q*, D1x, PORT*, R-N
    never appear in comments, identifiers, or prose — name the mechanism ("the
    x86-body gate", "the CPU-only-cycle flag"). Traceability to the project
    log is the commit message's job. Internal check names must not collide
    with the codename alphabet either (a gate's own "P2" vs project "P2b").
11. **Delete into docs, not into the void.** A unique fact with no home gets
    appended to the matching `hetlitmus/docs/` file (or REFERENCES.md entry)
    in the same change.

## Style

12. **Be concise.** File header ≤ 10 lines; block ≤ 5; inline ≤ 2. Over
    budget ⇒ the surplus moves to docs. Exception: het-runtime headers travel
    to GPU boxes without the repo — a knob a run is tuned with (a cap, a
    stride, a jitter) may keep 2–5 self-contained lines saying what it is and
    what an unmeasured value means. Everything else in those headers follows
    the budget, and maintainer notes live in `litmus/het-runtime/README.md`
    only — never in both the README and the header it describes.
13. **Tests get two lines.** In a gate script, cram file or Makefile target,
    every comment is ≤ 2 lines; the script's top docstring and the target
    header are governed by rule 7 instead. A cram block gets one sentence; a
    cram file opens with nothing but a pointer. Why the pinned property holds
    is the docs' to say and is not re-derived beside the check that pins it.
14. **Caps are hazard words only.** ALL-CAPS marks a word whose misreading
    inverts a correctness property (NOT, NEVER, ONLY, BOTH), ≤ 1 per comment.
    Never topic sentences, never nouns. A principle is stated once per file,
    not at every site applying it.

## Process

15. **Comments only; gates after every file.** A comment pass never touches
    emitted code, printf/echo strings, or printed check names (gates grep
    printouts; cram pins bytes). Removing codenames from runtime strings is a
    separate change with its own gate re-recording. Rebuild + run gates/cram
    per file; cram `grep -c` counts include comment lines, so re-record only
    after diffing the emitted artifact and confirming the delta is
    comment-only.
16. **Duplicate sweep closes a pass.** For each docs section a pass touched,
    grep its distinctive phrases across the repo; every hit outside that docs
    file is a restatement and becomes a pointer. A pass that leaves two homes
    for one sentence is not finished.
