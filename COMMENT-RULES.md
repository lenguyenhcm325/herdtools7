# HetLitmus code-comment rules

Scope: HetLitmus-added code only; upstream herdtools7 files keep upstream style.

The problem being fixed: comment blocks that narrate development history,
duplicate the specs in `env-research/` and `hetlitmus/docs/`, restate the same
caveat at several sites, and lean on milestone codenames (B*, DR*, F*, Q*) as
if the reader knows the project log. A reader who skips the blocks loses
nothing — which means the blocks are not doing a comment's job.

## Rules

1. **Present, not process.** State the invariant as it is now — no "used to
   be", no before/after bug stories. History lives in git log + impl-briefs.
   If a past bug justifies a guard: one sentence on what the guard prevents.
2. **One home per idea.** Explain once, at the definition site; elsewhere one
   line + reference. Never paste a caveat twice.
3. **Conclusion + pointer, not derivation.** Cite the doc/paper instead of
   re-deriving (math, quotes, fixture numbers). Exception: het-runtime headers
   travel to GPU boxes without the repo — run-time-critical constraints may
   keep 2–5 self-contained lines.
4. **Codenames are tags, not vocabulary.** At most one per block, e.g.
   "(B7; Q3-stats.md)". Prose uses mechanism names, not codenames.
5. **No reviewer rhetoric.** Cut sentences that argue the change is
   correct/sound/disclosed. A divergence from a cited source = one sentence
   + pointer.
6. **Keep the load-bearing lines** (tightened): non-local constraints,
   upstream-divergence facts, citation obligations, why-this-branch one-liners.
7. **Size budget.** File header ≤ 20 lines; block ≤ 10; inline ≤ 2. Over
   budget ⇒ rule-3 exception or the surplus moves to docs.
8. **Emphasis discipline.** ≤ 1 ALL-CAPS phrase per comment; a principle is
   stated once per file, not at every site applying it.
9. **Delete into docs, not into the void.** A unique fact with no home gets
   appended to the matching doc in the same change.
10. **Comments only; gates after every file.** Never touch emitted code or
    printf strings (verdictcheck greps printouts). Rebuild + run gates/cram
    per file; cram `grep -c` counts include comment lines, so re-record only
    after diffing the emitted artifact and confirming the delta is
    comment-only.
