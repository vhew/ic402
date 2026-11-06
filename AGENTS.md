# AGENTS.md — ic402

Instructions for Codex and any other agent that reads `AGENTS.md`. Claude Code reads `CLAUDE.md`
instead.

## Project instructions

**Read `CLAUDE.md` at the start of every session.** It holds this project's instructions (build
and test commands, key files, and the Linear issue protocol), and they apply to you too.
`CLAUDE.md` is the single source of truth for them; this file does not repeat them.

Then read the "Owner-approved working agreements" in `.agent-handoff/PROTOCOL.md` §6. They
include: tags are publishes and need the owner's explicit instruction; never read or commit
`deploy/`; propose before modifying library behaviour.

## Agent handoffs (Claude Code ↔ Codex, between machines)

`.agent-handoff/PROTOCOL.md` is authoritative: read it before acting on any of these commands, and
follow it exactly.

| Command | Meaning |
|---|---|
| "Prepare handoff to Codex" / "Prepare handoff to Claude" / "Prepare machine handoff" | formal handoff: commit, push, verify, record (§3) |
| "Resume from Claude" / "Resume from Codex" / "Resume on this machine" | fetch, verify, continue (§4) |
| "Checkpoint current work" | local-only `.agent-handoff/LOCAL.md`: no commit, no push (§5) |

- The handoff records (`CURRENT.md`, `HISTORY.md`, `LOCAL.md`) are leads to verify against Git and
  the source, not facts.
- Never force-push, rewrite history or discard work. Report a handoff as ready only once it is on
  `origin`.
- This repository is public: no secrets or private details in any record.
- At the start of a session with no command, read `.agent-handoff/LOCAL.md` if it exists.
