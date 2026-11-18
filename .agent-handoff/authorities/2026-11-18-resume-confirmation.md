# Resume confirmation — 2026-11-18

- [verified] Context: Claude resumed HO-20261108T2116Z-codex ("Resume from Codex") on
  2026-11-09 and sent the PROTOCOL §4 step 8 restatement: checkpoint and mismatches, the doctor
  verdict (tools NOT READY), ledger rows H1–H5, and nine decisions with recommendations. On
  2026-11-18 its next-steps message listed, as item 1 (formatting removed):

> 1. Confirm the handoff (one word). My earlier report on resuming from Codex is still waiting for
> your answer, and the handoff rules hold back building and committing until you give it. Reply
> "confirmed" to accept my recommendations, or correct any of them. That also closes the
> handoff-system work.

- [verified] The owner answered, exact text (spelling preserved):

> 1 confirmed. 2 approved all changes. 3 design fix use fable. smaller tems fox all as you recommended.

- [approved] "1 confirmed." accepts the nine recommendations below as written. Items 2–4 of the
  same message approve product work (PR #51 and a ledger-deduplication design); CURRENT.md records
  them, they are not handoff rulings.

## The nine decisions, quoted from the 2026-11-09 report (formatting removed)

1. "Push authority from now on. Recommended: the "this update" no-push limit ended with that
   update. Formal handoffs may push `chore/agent-handoff` and non-default code branches; nothing
   goes to `master` except release commits; tags only on your per-release instruction. Recorded
   with your exact words."
2. "The out-of-date "this update" lines. Recommended: one dated correction marking them no longer
   in force, since your rules say add, don't rewrite."
3. "The doctor's role. Recommended: freeze it as advisory, run the tools level on each resume, and
   add no new checks without a size estimate first."
4. "H3, my shell. Recommended: leave it until a product task needs `mops test`. Then, with your OK:
   activate the `ic402` environment, install `mops` 3.5.1, and put the project's `icp` 1.7.0 first
   on PATH."
5. "H4, the deploy guard. Recommended: put it explicitly on hold. No mainnet deploy is planned, and
   the real entry point is your private `deploy/` tooling, which agents can't read."
6. "Discovery from the main checkout. Recommended: pointers on this machine only, with no `master`
   change: an entry in my memory index, and a `~/.codex/AGENTS.md` line. Separately: should
   `master` get a product-only `AGENTS.md`, so Codex gets the project instructions?"
7. "Publish rules that live only in my private memory into the public `STANDING.md`, with dates:
   tags need your instruction, propose before modifying, and report size first. Recommended: yes,
   since Codex can't read my memory. Your call, because the repository is public."
8. "The PocketIC processes: are they yours? I'll leave them alone either way, but I need to know
   before running any replica tests."
9. "After you confirm: recommended to close the handoff-system work. Then return to product work
   through the usual proposal process: ledger deduplication, the stale `RELEASING.md` steps, and
   Dependabot PR #49."

## Notes

- [open] Decision 6's second question (a product-only `AGENTS.md` on `master`) had no
  recommendation, so "confirmed" does not answer it. CURRENT.md carries it as Q4.
- [verified] Decision 8 was a question, not a recommendation. A read-only check on 2026-11-09
  found that the running PocketIC processes belong to a sibling project's local network. They
  are not ic402's to stop.
- [verified] Dependabot PR #49 was later replaced by #50; PR #51 supersedes #50.
