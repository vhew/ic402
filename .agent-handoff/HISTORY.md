# Handoff history (append-only)

One entry per formal handoff, appended in the handoff commit itself (`.agent-handoff/PROTOCOL.md`
§3 step 9). Newest last. Never edit or delete past entries; if one turns out to be wrong, append a
correction. The full record of the latest handoff is `CURRENT.md`, and older records are in Git
(`git log -p -- .agent-handoff/CURRENT.md`). This file is public: no secrets or private details.

Entry format:

```
## HO-yyyymmddTHHMMZ-<from> — <from> -> <to> [(machine)]
- Branch / implementation commit: <branch> @ <short SHA>
- Progress: <one or two lines>
- Decisions: <new decisions, if any>
- Risks / open: <what the receiver must watch>
```

---

## HO-20261106T1528Z-claude — claude -> codex
- Branch / implementation commit: chore/agent-handoff @ 553ff1f
- Progress: the handoff system is set up (PROTOCOL, CURRENT, HISTORY, BOOTSTRAP, AGENTS.md, and a
  CLAUDE.md section). The library is at v2.20.0 (released, master 3af30b4).
- Decisions: AGENTS.md defers to CLAUDE.md; working agreements are copied into PROTOCOL §6;
  handoff commits stay off master. Each awaits the owner's review.
- Risks / open: chore/agent-handoff is not merged; Codex discovery is untested; the follow-ups
  are listed in CURRENT.md.

## Policy correction — 2026-11-06 (owner instruction; not a new handoff)

- Supersedes the merge suggestions in HO-20261106T1528Z-claude and earlier local checkpoints.
- The owner requires this setup to remain on `chore/agent-handoff`, never merged into `master`
  or product branches. No PR is needed or wanted for merging the setup.
- Future code work starts from `origin/master` or a clean implementation branch. Records and
  implementation branch/commit references are separate; metadata stays on the records branch.
- A public branch is public. Purging is not a privacy guarantee and requires separate explicit
  authorization; no branch deletion or history rewrite is authorized by this policy update.
- Codex discovery succeeded; the resume reran `mops test` with 731 passing. No PR or merge was
  created. The existing setup branch and history are preserved.


## Local protocol update — 2026-11-08 (not a formal handoff)

- [approved] Owner requested additive lessons, doctor/probes, template and standing instructions;
  no push unless asked. Source: `authorities/2026-11-08-owner-request.md`, committed at `999aeb3`.
- [verified] Helper/protocol commit `ccef51a`; independently checked evidence commit `28c0cd9`.
  All prior protocol/entry-point lines retained; CURRENT.md has an additive local task ledger.
- [verified] 44 failure probes across 29 IDs pass under Bash and Zsh. Real doctor remains NOT READY;
  details and limits in committed VALIDATION.md. No application changes, deployment, tag or push.
- [open] Real ready-machine control, authoritative production target/guard integration and CI-held
  publishing credential usability are unresolved. Historical handoff 1821c10 is not reclassified.


## HO-20261108T2116Z-codex — codex -> claude (prepared locally)

- [verified] Branch / metadata implementation: chore/agent-handoff @ 383b7fe; product baseline
  master @ 3af30b4. This entry describes preparation, not successful remote synchronization.
- [verified] Progress: lessons/template/standing instructions and read-only doctor are implemented;
  existing Bash/Zsh logs pass 44 failure probes / 29 check IDs. Fresh tools doctor is NOT READY.
- [assumed] Decisions: Python stdlib runtime and explicit JSON target profile; rationale/undo in
  CURRENT.md/DOCTOR.md. No new product decision or production target was invented.
- [open] Risks / next: explicit push approval still needed; shell prerequisites and real green
  control owed; production target/guard integration unresolved; existing PocketIC ownership unknown.
- [approved] Never merge this metadata into master; receiver follows STANDING.md and restates
  the ledger/design/doctor verdict for owner confirmation before building.


### Publication correction — HO-20261108T2116Z-codex (2026-11-08)

- [approved] Owner answered “yes” to pushing the prepared records branch; authority committed
  at 8d64cf2 and verified on origin before this correction. This resolves the prior push-pending note.
- [verified] Implementation 383b7fe and handoff efc63c1 are both on origin/chore/agent-handoff.
  master remains unchanged at 3af30b4. Read the branch-tip CURRENT correction when resuming.
- [open] The existing doctor/readiness and production guard decisions remain unresolved.
