# Current formal handoff

> **Owner policy update, 2026-11-06:** the record below describes the earlier setup handoff.
> Its suggestions to open a PR or merge the setup are superseded. **Never merge this setup into
> master or product branches.** Keep it on `chore/agent-handoff`, which is public, not semi-private.
> No purge or history rewrite is authorized. Read the latest PROTOCOL.md from the records branch
> before acting on any historical record. Code work uses a separate clean implementation branch.
> Codex verified the handoff and reran `mops test` (731 passed); discovery worked. No PR or merge
> was created. The historical implementation is **metadata only**, not a base for future code work.
> This policy addendum is not a new formal handoff; the original handoff commit remains 1821c10.

The latest synchronized formal handoff. Procedure: `.agent-handoff/PROTOCOL.md` §3 (prepare) and §4
(resume). Everything here is a lead to verify against Git and the source.

## Handoff
- ID: HO-20261106T1528Z-claude   Time (UTC): 2026-11-06 15:28
- From: claude   To: codex
- Implementation commit: `553ff1f89aa2978f4bdd81398771fb34f3dafa5e` on branch `chore/agent-handoff`;
  on origin: yes (verified `HEAD == origin/chore/agent-handoff` after fetch).
- Handoff commit: the commit that contains this file. It is not recorded here; find it with
  `git log --remotes=origin --grep='^handoff: HO-'`.

## Task
- Objective: the one-time setup of this handoff system, then normal ic402 maintenance under the
  owner's direction. No feature work is in progress.
- Owner-approved requirements (owner's setup request, 2026-11-06):
  - one shared protocol for both agents;
  - formal handoffs are Git commits and pushes, verified on the remote;
  - a git-ignored local checkpoint;
  - same procedure for machine switches;
  - seven natural-language commands;
  - no application-code change; no force-push or history rewrite.
- Acceptance: either agent can continue from the repository alone, without the other's
  conversation history.

## Constraints and invariants
- Project instructions: `CLAUDE.md`, which applies to Codex too. Working agreements:
  `PROTOCOL.md` §6. Tags are publishes (owner's explicit instruction only); `deploy/` holds keys
  (never read or commit it); propose before modifying library behaviour; adversarial review and
  mutation-verified tests before every release.
- Funds-related design: `docs/security-model.md`, `docs/fund-safety-invariants.md`,
  `docs/recovery-runbook.md`, `docs/upgrade-safety.md`.
- The repository is public: no secrets or private details in commits or records.

## Decisions
- Approved by the owner: the handoff structure and commands as specified in the setup request.
- Agent assumptions, not yet approved by the owner:
  - **(a)** `AGENTS.md` sends Codex to `CLAUDE.md` rather than duplicating it.
  - **(b)** `PROTOCOL.md` §6 copies the standing working agreements into the repository. They
    previously existed only in Claude's private memory, which Codex cannot read.
  - **(c)** Handoff commits never go to `master`. When idle on `master`, they go to a
    `handoff/<ID>` branch.

  The owner may trim (b) before merging, since the repository is public.
- Rejected: Claude's `@AGENTS.md` import pattern. It would have moved all of `CLAUDE.md`'s content
  into a new file, a wholesale rewrite the setup request ruled out.

## State
- Done (verified):
  - the handoff-system files are committed on `chore/agent-handoff` (`553ff1f`) and pushed;
  - `.agent-handoff/LOCAL.md` is git-ignored;
  - `master` is at `3af30b4` (`release: v2.20.0`), published on npm and mops.
- Incomplete: `chore/agent-handoff` is not merged into `master` and has no PR. Opening and merging
  one is the owner's decision; the repo convention is a PR merged with `--merge`.
- Known bugs or failures: none known.
- Open items, not in progress (the owner decides):
  - **A pending ICP charge has no in-band resolution.** 2.20.0 returns `#settlementPending` with
    the nonce locked; ledger dedup (`created_at_time` + `memo`) is the structural fix.
  - **Session open does not catch a reject on its deposit pull.** This is a documented residual;
    fixing it needs a new session state.
  - **`RELEASING.md` steps 6–7 are stale** (manual npm publishing). Publishing is the tag push.
  - **Dependabot PR #49** (an npm minor/patch group) has not been reviewed.
  - **A shelved stash (`stash@{0}`, voucher hardening)** exists on the outgoing machine only;
    the owner called it superseded.
- Open questions for the owner: approve or trim §6 and decisions (a) to (c); merge
  `chore/agent-handoff`?

## Files
- `.agent-handoff/PROTOCOL.md`: the procedure. Read §1, §4 and §6 first.
- `AGENTS.md`, plus the "Agent handoffs" section at the end of `CLAUDE.md`: the entry points.
- `CHANGELOG.md` (v2.18.2 to v2.20.0): the most recent library work.

## Tests actually run
- For this change: none, because it is documentation and config only. `git check-ignore` confirms
  `LOCAL.md` is ignored. The handoff-subject query was tested in a throwaway scratch repository.
- Last full run on the library: `mops test`, 731 passing, and CI (16 checks) green on PR #48
  (`2e47efc`), the commit released as v2.20.0. Not re-run since.

## Next actions (in order)
1. **Resume (Codex):** follow `PROTOCOL.md` §4. Confirm you loaded `AGENTS.md` and then read
   `CLAUDE.md` and `PROTOCOL.md`, and tell the owner whether discovery worked. This system has
   not yet been tested with a real Codex session.
2. **Check out `chore/agent-handoff`** and verify the files match this record (`git show --stat 553ff1f`).
3. **Ask the owner** whether to open a PR for `chore/agent-handoff`, and whether to trim §6 or
   change decisions (a) to (c).
4. **Then whatever the owner asks next.** Candidate work is the open items above, each with a
   proposal first.
