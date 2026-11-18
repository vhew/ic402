# Standing owner instructions

- [approved] 2026-11-08: this file persists across handoffs; records cite it instead of repeating it.
  Add/change a ruling only from an owner instruction, with date and source; retain an old line and
  place its dated correction beside it. Read applicable project instructions and protocol too.
- [verified] Quote source: [owner-request excerpts](authorities/2026-11-08-owner-request.md).
  The excerpts were committed first at `999aeb3`; unpublished drafts confer no
  synchronized-handoff status. The original conversation remains the source of the transcription.

| ID | Classification | Date | Exact owner quotation | Written source / scope |
|---|---|---|---|---|
| S1 | approved | 2026-11-06 | “i want to never merge this to master.” | owner-request excerpts R1; handoff setup branch |
| S2 | approved | 2026-11-08 | “Keep every existing rule.” | R2; protocol update |
| S3 | approved | 2026-11-08 | “Add to it; do not rewrite it.” | R2; protocol update |
| S4 | approved | 2026-11-08 | “The owner confirms or corrects once.” | R3; receiving a handoff |
| S5 | approved | 2026-11-08 | “Only include rules this repo's owner has actually stated.” | R5; standing instructions |
| S6 | approved | 2026-11-08 | “Do not push unless I ask.” | R6; this update, until an explicit push request |
| S6 correction | approved | 2026-11-08 | “yes” | authorities/2026-11-08-claude-handoff.md, Publication approval; permits this prepared Claude handoff push only |
| S6 correction 2 | approved | 2026-11-18 | “1 confirmed.” | authorities/2026-11-18-resume-confirmation.md, decision 1. S6 was scoped to the 2026-11-08 update and has lapsed. Formal handoffs and resumed work may push `chore/agent-handoff` and non-default code branches; nothing goes to `master` except release commits (and PR merges the owner asks for); tags only on the owner's per-release instruction |
| S7 | approved | original undated; published 2026-11-18 | “push the tag, but you need my explicit instruction to do so. dont do it automatically.” | Claude's machine-local memory, published by authorities/2026-11-18-resume-confirmation.md decision 7; every `vX.Y.Z` tag (a tag push is the npm + mops publish) |
| S8 | approved | 2026-11-18 | “1 confirmed.” (original wording not recorded) | authorities/2026-11-18-resume-confirmation.md decision 7: propose before modifying — verify a report against the source, show the change, wait for the owner's “yes” |
| S9 | approved | 2026-09-30; confirmed 2026-11-18 | “this seems massive. is this in line with the purpose of ic402?” (2026-09-30, on a 4,055-line patch); “1 confirmed.” | authorities/2026-11-18-resume-confirmation.md decision 7: report the size of a change (src / test / docs lines) before building it |

- [open] Protocol §6 contains earlier attributed working agreements whose verbatim original
  owner messages are not in the repository. Keep those existing rules; do not invent quotations
  or promote agent paraphrases to quoted owner rulings. Record missing rationale as lost/open.
- [approved] 2026-11-18 correction beside the line above: the owner confirmed publishing three
  agreements (decision 7 of the resume confirmation): tags, propose before modifying, and size
  first, now S7–S9. The other §6 agreements keep the open provenance noted above.
- [approved] Do not import the sibling project's example standing rules as this owner's rulings.
