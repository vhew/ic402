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
