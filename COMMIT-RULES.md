# HetLitmus commit-message rules

Scope: commits on the HetLitmus branches. Upstream herdtools7 commits keep
upstream style.

## Rules

1. **Blank line after the subject, always.** Without it git reads the whole
   first paragraph as the subject — the one breach here that corrupts
   tooling rather than taste.
2. **Subject ≤ 72 chars**, target ≤ 65, no trailing period. 72 keeps it
   inside 80 columns under `git format-patch`'s `[PATCH] ` prefix.
3. **A subject is a thesis, not an inventory.** A commit may carry several
   changes; the subject names what the commit as a whole establishes and
   the body enumerates the parts. Listing what the patch touched is what
   pushes a subject past 72 chars. The whole subject line reads

       PORT1 c4: campaign.py's header skip accepts both real control maps

   (66 chars) and not

       PORT1 c4: campaign.py reads control-map.csv -- fix the header skip,
       gate both real files

   (88, an inventory of the patch that never says what was wrong). That the
   skip had tested the wrong column name, that the scheduler died on the
   header row, and that a gate now parses both files, is body. When no
   honest subject covers every part, name the largest and let the body
   carry the rest.
4. **Present tense, naming the change, not the defect.** State what the
   commit establishes — "the pair table stops deciding who may emit", "the
   ordering gate becomes the lattice gate" — so a reader of `--oneline`
   knows what was done. "campaign.py's reader skipped a real row" describes
   the old world and leaves it open whether this commit caused, found or
   fixed it.
5. **Subject form: `STREAM STEP: thesis`, when the commit implements a
   plan.** STREAM is that plan's ALL-CAPS id (`CHAR`, `NVOR`, `MV`, `PORT1`,
   `PORT2`, `Q10`, `DR1`), STEP its own step id verbatim (`A3`, `D2a`, `c1`,
   `F`); omit the word "Phase". A commit implementing several steps of one
   plan joins their ids (`A3+A4`, `c1-c3`). A commit under no plan takes
   the gate or file it repairs, spelled as that file is (`x86bodycheck:`,
   `Makefile:`) so it cannot be read as a stream tag, or no prefix
   at all when it has no single home ("X2A_TRANSFERS=1 must be runnable,
   and it is not byte-for-byte"). Never invent a STREAM to fill the slot:
   the tag exists so a plan's commits can be listed later, and a one-off
   tag is worse than none.
6. **A review-closure suffixes the step it repairs** (`A3` → `A3b`) and
   carries `Closes-review:`. Keep the relationship out of the subject
   ("Close the C+D review findings:", "P2b follow-up:") — it is metadata,
   and it costs the chars rule 3 needs.
7. **Body: what changed, why it had to, what moved as a consequence.** The
   test, per line: would it survive if the reader had the diff open? A
   file-by-file walkthrough fails; the why, the defect class, the measured
   deltas, what a reader of a results tree would otherwise miss, and what
   was deliberately not done all pass. Depth is not rationed.
8. **Body ≤ 100 lines**, trailers excluded — a comment, stale-number or
   mechanical fix ≤ 15; a change to behavior or emitted bytes 30–80; a
   change that moves a census, an oracle or a verdict surface may use it
   all. A commit carrying several changes takes the budget of its largest
   part; the 100-line cap still holds. Surplus goes to the brief in
   `env-research/`, named in the body.
   Past ~60 lines the body must be scannable: ALL-CAPS paragraph leads
   (`THE FAIL-CLOSED REPLACEMENT.`) or `F1.`/`F2.` numbering.
9. **Wrap at 76, hard limit 80**, exempting a line held long by an
   unbreakable token — path, URL, sha, aligned citation or table row.
10. **ASCII only.** `mu(T)`, `->`, `--`, `sect 4.6`, `>=`.
11. **Trailers are optional; their spelling is not.** Final paragraph,
    continuation lines indented two spaces, ≤ 8 lines each and ≤ 20 for the
    paragraph — a trailer is an index, so anything longer is a body
    paragraph wearing a key.
    - `Verified:` — commands run and their result. Include it whenever the
      commit changes behavior; it is what makes the claim checkable later.
    - `Closes-review:` — `<sha>` of the reviewed commit. Required by rule 6.
      The body says what was fixed.
    - `Co-Authored-By:` — any form.

    No other keys, and no verification evidence under a header of its own
    invention: a trailer above, or ordinary body prose.
12. **Never a claude.ai URL, session link, or `Claude-Session:` trailer.**
    Git history is permanent and thesis-facing.
13. **Every number is one you ran** — counts, censuses, file tallies,
    byte-identity claims. A stale count in a message is the same defect as
    a stale count in a comment.
