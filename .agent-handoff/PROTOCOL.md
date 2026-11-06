# Agent handoff protocol (authoritative)

How Claude Code and OpenAI Codex hand work to each other, or to themselves on another machine,
without losing context. Both agents follow **this file**; `CLAUDE.md` and `AGENTS.md` only point
here. If anything else disagrees with this file about handoffs, this file wins.

- **Formal handoff:** committed and pushed to `origin`. It is the only kind another agent or
  another machine can rely on. Its record is `.agent-handoff/CURRENT.md`, with one line per
  handoff in `.agent-handoff/HISTORY.md`.
- **Local checkpoint:** `.agent-handoff/LOCAL.md`, git-ignored, never committed or pushed. It
  exists only on the machine that wrote it.
- **New machine:** see `.agent-handoff/BOOTSTRAP.md`.

**This repository is public.** Everything committed here, handoff records included, is published.
Never record secrets, keys, tokens, account names, local paths, private repository contents, or
anything the owner has not approved to be public. Refer to private context by its location
("the owner has it", "see the issue tracker"), not its contents.

## 1. Commands

| The owner says | Do |
|---|---|
| "Prepare handoff to Codex" | §3 formal handoff; receiver = `codex` |
| "Prepare handoff to Claude" | §3 formal handoff; receiver = `claude` |
| "Prepare machine handoff" | §3 formal handoff; receiver = the same agent, on another machine |
| "Resume from Claude" | §4 resume from the newest formal handoff made by `claude` |
| "Resume from Codex" | §4 resume from the newest formal handoff made by `codex` |
| "Resume on this machine" | §4 resume from the newest formal handoff, whoever made it |
| "Checkpoint current work" | §5 local checkpoint; no commit, no push |

Agent names in records are exactly `claude` and `codex`.

**IDs.** A formal handoff is `HO-<UTC yyyymmddTHHMMZ>-<from>`, for example `HO-20261106T1430Z-claude`.
A local checkpoint is `LC-<UTC yyyymmddTHHMMZ>-<agent>`. Take the time from `date -u +%Y%m%dT%H%MZ`.

**Handoff commit subject:** `handoff: <ID> <from>-><to>`. For a machine handoff, add ` (machine)`
after it, for example `handoff: HO-20261106T1430Z-claude claude->claude (machine)`. The `handoff: `
prefix is how §4 finds handoffs, so use it exactly.

## 2. Rules for every handoff and resume

- **Verify, don't trust.** Every claim in CURRENT.md or LOCAL.md is a lead to check against
  `git` and the source, never ground truth.
- **Never destroy work.** No force-push, history rewrite, `reset --hard`, `checkout -- .`,
  `clean`, branch deletion, or stash drop, and never overwrite divergent work. If a step would
  need one of these, stop and report.
- **Stage by name.** Never `git add -A` or `git add .`. Review `git diff --cached` before every
  commit. Leave unrelated changes uncommitted and say so.
- **Never commit** secrets, `deploy/` (git-ignored; it holds real keys, so never read or print it
  either), `.env*`, `*.pem`, `*.key`, `.local/`, `.claude/`, `LOCAL.md`, build output, or other
  machine-specific files.
- **Follow the project's commit conventions:** `type(scope): subject`, with the trailer the
  current agent's own attribution rules require.
- **Never commit to `master` directly with task work.** Work happens on a branch: `feat/…`,
  `fix/…`, `chore/…`, `test/…`, or `wip/…` when unsure. `master` takes merges (`--merge`, never
  squash) and `release:` commits.
- **A formal handoff authorizes** ordinary reviewed commits, and pushes of non-default branches
  to `origin`. It does **not** authorize pushing to `master`, tags (a `vX.Y.Z` tag publishes to
  npm and mops), merging PRs, or anything else the owner has not explicitly asked for.

## 3. Formal handoff (all three "Prepare …" commands)

The same procedure applies whether the receiver is the other agent, the same agent on another
machine, or both.

### Phase A: inspect

```bash
git rev-parse --show-toplevel; git branch --show-current; git rev-parse HEAD
git remote -v; git fetch origin --prune
git status --short --branch          # ahead/behind, staged, unstaged, untracked
git log --oneline @{u}..HEAD 2>/dev/null || echo "no upstream"   # unpushed commits
git stash list
```

1. Sort every changed or untracked file into one of: task work, unrelated work (leave it), or
   must-never-commit (§2). Check diffs for secrets before staging anything.
2. Note what is done, what is incomplete, and what is blocked. Note the tests you actually ran
   and their results; tests you did not run must not be reported as passing.
3. If the branch has **diverged** from its upstream (both ahead and behind), stop. Don't merge,
   rebase or push. Report the handoff as **incomplete** with the divergence.

### Phase B: commit and push the implementation

4. If you are on `master` with uncommitted task work, create a task branch first:
   `git switch -c <type>/<slug>`.
5. Stage the task files by name and commit. Unfinished work is fine as `wip(scope): …`. If
   nothing is uncommitted, skip the commit.
6. Push: `git push -u origin <branch>`. If the branch is `master` and there is no task work,
   nothing is pushed in this phase.
7. Verify, and record the result as the **implementation commit**:
   ```bash
   git fetch origin
   test "$(git rev-parse HEAD)" = "$(git rev-parse origin/<branch>)" && echo synced
   ```

### Phase C: record and push the handoff

8. Make the ID, then rewrite `.agent-handoff/CURRENT.md` to its template (keep the headings).
   Record the implementation commit's full SHA and branch. **Do not try to record the handoff
   commit's own SHA**; it is whatever commit contains this CURRENT.md, and §4 finds it with
   `git log`.
9. Append one entry to `.agent-handoff/HISTORY.md` (format at the top of that file).
10. Commit only those two files: `git add .agent-handoff/CURRENT.md .agent-handoff/HISTORY.md`,
    with the subject from §1.
    - **On a task branch:** commit there.
    - **On `master` with no task branch** (for example, idle after a release): create
      `handoff/<ID>` from `master` and commit there. `master` stays untouched; the owner can
      merge or delete that branch later.
11. Push it and verify, as in step 7.
12. Report **"Handoff ready"** with the ID, the implementation commit, the handoff commit and the
    branch, and give the receiver's resume command. Report it **only** if both commits are on
    `origin`.
13. If anything failed, report which steps succeeded and which did not, the exact error, and what
    is left on this machine. Write a local checkpoint (§5) so nothing is lost. **Never** call an
    incomplete handoff ready.

## 4. Resume (all three "Resume …" commands)

1. **Look before touching anything:** run `git status --short --branch`, `git stash list` and
   `git branch --show-current`. If there are local changes, keep them; don't switch branches over
   them. Ask the owner, or commit them to their own branch first.
2. `git fetch origin --prune`. Never `pull` into a branch with local changes or divergence.
3. Find the newest formal handoff on the remote:
   ```bash
   git log --remotes=origin --grep='^handoff: HO-' --format='%h %cI %s%n    %D' -n 5
   ```
   For "Resume from Claude" or "Resume from Codex", take the newest entry whose subject says
   `claude->` or `codex->`. For "Resume on this machine", take the newest of any. Read the record
   without switching branches:
   `git show <handoff-sha>:.agent-handoff/CURRENT.md`.
4. Verify the implementation commit named in the record is on the remote:
   `git branch -r --contains <impl-sha>`. If it isn't, the handoff is broken. Go to §7.
5. **Look for newer work than the handoff:** commits on that branch after the handoff commit
   (`git log <handoff-sha>..origin/<branch>`), and the local `.agent-handoff/LOCAL.md` if this
   machine has one. Newer work wins over the record; never discard it.
6. Check out the branch (`git switch <branch>`, tracking `origin/<branch>`), fast-forward only.
7. Read `CLAUDE.md`, this protocol, and the documents the record names as authoritative. Then
   verify the record's claims that matter against the source, and re-run the tests it names.
   Note any discrepancy and tell the owner.
8. Tell the owner, briefly: what you verified, the task, and the first next action. Then continue
   from the verified state, without redoing completed work.

## 5. Local checkpoint ("Checkpoint current work")

1. Collect the current Git state: branch, HEAD, ahead/behind, and staged/unstaged/untracked file
   names.
2. Overwrite `.agent-handoff/LOCAL.md` with: the ID; the time; the agent; the task and progress;
   important decisions; that Git state; incomplete work; known failures; and the immediate next
   steps.
3. Don't commit, push or stage it, and don't touch CURRENT.md or HISTORY.md. Confirm
   `git check-ignore .agent-handoff/LOCAL.md` prints the path.
4. Tell the owner it exists only on this machine. If the work must move machines, it needs a
   formal handoff.

When starting a session without a command, read LOCAL.md if it exists. Like a record, it's a lead
to verify.

## 6. Architectural continuity

- The authoritative project documents are `CLAUDE.md`, `README.md`, `CHANGELOG.md`,
  `RELEASING.md` and the files in `docs/`. In `docs/`, read `security-model.md`,
  `fund-safety-invariants.md`, `recovery-runbook.md`, `upgrade-safety.md` and `decisions/` first
  for anything touching funds. CURRENT.md points to these documents; it does not copy them.
- Keep the owner's approved decisions separate from your own assumptions. Label which is which in
  the records.
- Record a significant new decision where it will last: `docs/decisions/<topic>.md`, the
  CHANGELOG entry, or the code comment at the site. Keep its rationale, and any rejected
  alternative worth remembering. Record it in CURRENT.md as well.
- If the record, the documents and the code disagree, say so before changing the established
  design. Don't silently follow the previous agent.

### Owner-approved working agreements

These standing rules apply to both agents:

- **Propose before modifying.** When a report or request asks for a change to library behaviour,
  verify it against the source, show the proposed change, and wait for the owner's "yes".
  Routine tasks the owner explicitly asks for are already approved.
- **Releases** follow `RELEASING.md`, with one correction: publishing is done by pushing the
  `vX.Y.Z` tag, which triggers the release workflow (npm via OIDC, and mops). Before every
  release, run an independent adversarial review of the diff and mutation-verify the tests, so a
  check that is reverted makes its test fail. The release itself is a feature PR merged with
  `--merge`, then a `release: vX.Y.Z` commit on `master` (via `scripts/version.sh`, plus the
  version line in `docs/production-readiness.md`).
- **Tags are publishes.** Never create or push a tag without the owner's explicit instruction for
  that specific release.
- **`deploy/`** is git-ignored and holds real private keys. Never read, print or commit it.
- **CI pins.** Every toolchain version in `.github/workflows/ci.yml` and `mops.toml` is pinned
  for a documented reason. Read the comment before changing one.

## 7. Recovery when a handoff was interrupted

The previous agent may have stopped mid-handoff, for example when it ran out of usage.

1. Find the last **synchronized** handoff with §4 step 3. That record is the baseline.
2. Look for anything newer: remote branches updated after it (`git branch -r --sort=-committerdate`),
   unpushed local commits, uncommitted changes, stashes, and LOCAL.md.
3. Reconstruct the state from Git, the source, tests and the docs. Where they disagree with the
   records, Git and the source win.
4. If something newer exists only on another machine, say so; it can't be recovered from here.
5. Continue from the verified state. If the owner wants the record repaired, do a fresh formal
   handoff (§3), not an edit to an old one.

## 8. Errors

Report plainly what failed: the step, the command and its error. Report what was done, what is
left, and what the owner needs to do. Prefer stopping over improvising, especially for anything
in §2.
