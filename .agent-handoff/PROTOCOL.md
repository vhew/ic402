# Agent handoff protocol (authoritative)

How Claude Code and OpenAI Codex hand work to each other, or to themselves on another machine,
without losing context. Both agents follow **this file**; `CLAUDE.md` and `AGENTS.md` only point
here. If anything else disagrees with this file about handoffs, this file wins.
Always load the latest version from `origin/chore/agent-handoff` after fetching; a historical
handoff may contain superseded instructions.

- **Records branch:** `chore/agent-handoff`, permanently separate from `master`. It holds this
  setup, protocol, bootstrap guide, and records. Never merge it into `master` or a product branch.
- **Formal handoff:** implementation committed and pushed on its own code branch; records
  committed and pushed on the records branch. Its record is `.agent-handoff/CURRENT.md`, with
  one line per handoff in `.agent-handoff/HISTORY.md`. Both must be verified on `origin`.
- **Local checkpoint:** `.agent-handoff/LOCAL.md`, git-ignored, never committed or pushed. It
  exists only on the machine that wrote it.
- **New machine:** see `.agent-handoff/BOOTSTRAP.md`.

**This repository is public.** Everything committed here, handoff records included, is published.
Never record secrets, keys, tokens, account names, local paths, private repository contents, or
anything the owner has not approved to be public. Refer to private context by its location
("the owner has it", "see the issue tracker"), not its contents.

**Separate does not mean private.** A branch in this public repository remains public. Deleting
files, deleting a branch, or rewriting history cannot guarantee removal from clones, forks,
caches, or other references. Do not call this setup private or semi-private. Use local-only
storage or a separately authorized private repository for private context. Purging is not a
privacy mechanism and is never automatic; any deletion or history rewrite needs a separate,
explicit owner instruction specifying its scope.

## Branch separation (owner-approved, 2026-11-06)

- **Never merge this setup into `master`.** Do not open a PR to merge the records branch. Do not
  merge, cherry-pick, or copy its handoff files/setup changes into product branches. This includes
  this branch's `AGENTS.md`, the handoff additions to `CLAUDE.md` and `.gitignore`, and
  `.agent-handoff/`. Keep any pre-existing project instructions on product branches intact.
- **Code branches start from `origin/master` or a verified clean implementation branch**, never
  from the records branch. Do not develop product code on `chore/agent-handoff`. Its code files
  are an old snapshot, not the current implementation. Read build/test instructions and design
  documents from the actual implementation branch.
- **Use separate working directories.** Reuse an existing records worktree (check `git worktree
  list`) or create one with `git worktree add <records-worktree> chore/agent-handoff` after fetching
  and establishing the tracking branch. Keep product work in another checkout/worktree. Do not
  switch over uncommitted work or check out the same branch in two worktrees.
- **Before a product PR/merge**, inspect the commit history and changed paths relative to
  `origin/master`. Verify that the setup commit `553ff1f89aa2978f4bdd81398771fb34f3dafa5e` is NOT
  an ancestor of the proposed code branch (`git merge-base --is-ancestor <setup-sha> <code-branch>`
  must return 1; errors are not proof). Check that no handoff files/setup changes were copied in.
  If contaminated, stop: removing the files in a later commit does not remove them from history.
  Propose a clean branch and transfer only reviewed product changes without rewriting the old one.
- **No main-branch changes are needed to discover handoffs.** After fetching, read the protocol
  with `git show origin/chore/agent-handoff:.agent-handoff/PROTOCOL.md`. Start agents in the records
  worktree, or explicitly provide that instruction when starting in a product checkout. The
  records branch's entry points are not automatically present on `master`.
- **Local checkpoints on product branches:** before writing `.agent-handoff/LOCAL.md`, add that
  exact path to the clone's local exclude file (`git rev-parse --git-path info/exclude`) if missing.
  Verify with `git check-ignore .agent-handoff/LOCAL.md`. Never modify the product branch's tracked
  `.gitignore` just for handoffs. This also prevents a checkpoint left behind by switching branches
  from becoming an untracked file eligible for accidental staging.
- This is an agent workflow rule, not server-enforced branch protection. A non-default branch is
  still public, and preserving it separately is not a privacy guarantee.

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
  need one of these, stop and report. A discussion of periodic cleanup is not authorization.
- **Stage by name.** Never `git add -A` or `git add .`. Review `git diff --cached` before every
  commit. Leave unrelated changes uncommitted and say so.
- **Never commit** secrets, `deploy/` (git-ignored; it holds real keys, so never read or print it
  either), `.env*`, `*.pem`, `*.key`, `.local/`, `.claude/`, `LOCAL.md`, build output, or other
  machine-specific files.
- **Follow the project's commit conventions:** `type(scope): subject`, with the trailer the
  current agent's own attribution rules require.
- **Never commit to `master` directly with task work.** Work happens on a branch: `feat/…`,
  `fix/…`, `chore/…`, `test/…`, or `wip/…` when unsure. `master` takes merges (`--merge`, never
  squash) and `release:` commits for product work only. Handoff/setup branches never merge there.
- **A formal handoff authorizes** ordinary reviewed commits, and pushes of non-default branches
  to `origin`. It does **not** authorize pushing to `master`, tags (a `vX.Y.Z` tag publishes to
  npm and mops), merging PRs, or anything else the owner has not explicitly asked for.

## 3. Formal handoff (all three "Prepare …" commands)

The same procedure applies whether the receiver is the other agent, the same agent on another
machine, or both.

### Phase A: inspect both working directories

1. Identify the implementation branch/worktree and the records branch/worktree separately. Run
   `git status --short --branch`, `git branch --show-current`, `git rev-parse HEAD`, and
   `git stash list` in each. Fetch `origin` and compare each branch with its upstream.
2. Classify changed files: product work, handoff metadata, unrelated work (leave it), or
   must-never-commit (§2). Check intended commits for secrets. Do not copy private context.
3. If either branch has diverged, stop. Do not merge, rebase, or push it. Note completed work,
   incomplete work, blockers, and only the tests actually run. Ensure the code branch satisfies
   the separation checks above before continuing.

### Phase B: commit and push the implementation

4. On `master` with task work, create a clean task branch before committing. If working on the
   records branch, only handoff-system maintenance belongs there; create a separate code worktree
   from `origin/master` for any product work. A metadata-only task can name the records branch as
   its implementation branch, explicitly marked **metadata only** in CURRENT.md.
5. Stage product task files by name in the code worktree, review `git diff --cached`, and commit.
   Unfinished work may use `wip(scope): …`. Skip this commit if nothing changed. Do not stage the
   records or local checkpoint. Leave unrelated work untouched and report it.
6. Push the implementation branch to `origin`. If idle on `master`, do not push it; verify that
   the intended implementation commit is already on `origin/master`. For metadata-only work,
   commit and push the setup changes on the records branch instead; never open a product PR.
7. Fetch and compare full local and remote SHAs. Record the **implementation branch and full
   commit SHA** only after verifying they match. Never claim a local-only commit is delivered.

### Phase C: record and push on the records branch only

8. In the records worktree, confirm the branch is `chore/agent-handoff`, fast-forward only if
   clean and behind, then make the ID. Rewrite `.agent-handoff/CURRENT.md` using its headings.
   Record the implementation branch/SHA, records branch, task type (product or metadata only),
   verified progress, decisions, tests, and next steps. Do not record the handoff commit's own SHA;
   discovery finds it through the commit subject. The implementation and records branches may
   differ; never infer one from the other.
9. Append an entry to `.agent-handoff/HISTORY.md`. Keep earlier entries unchanged; append a
   correction if an earlier claim or policy has been superseded.
10. Stage only CURRENT.md and HISTORY.md by name **in the records worktree**, review the staged
    diff, and commit with the §1 handoff subject. Never write these records onto a code branch,
    including when idle on `master`. Do not create disposable `handoff/<ID>` branches.
11. Push `chore/agent-handoff`, fetch, and verify its local HEAD equals
    `origin/chore/agent-handoff`. Do not merge it, open a merge PR, or delete it after handoff.
12. Report **"Handoff ready"** only when both implementation and record commits are on `origin`.
    Include the ID, both SHAs, both branch names, and the receiver's resume command.
13. On failure, report the exact failed step, what succeeded, and what remains local. Write a
    local checkpoint (§5). Never call an incomplete handoff ready.

## 4. Resume (all three "Resume …" commands)

1. **Look before touching anything:** inspect status, stash, current branch, and worktrees. Keep
   local changes. Do not switch branches over them; use an existing clean worktree or ask the
   owner if preserving them requires a decision.
2. Fetch `origin` and read the latest protocol with
   `git show origin/chore/agent-handoff:.agent-handoff/PROTOCOL.md`. This policy overrides older
   records, including earlier suggestions to merge the setup. Never pull into local changes or
   divergence.
3. Search the records branch, filtering the sender **before** limiting results:
   ```bash
   # Resume from Claude
   git log origin/chore/agent-handoff --grep='^handoff: HO-.* claude->' --format='%H %cI %s' -n 1
   # Resume from Codex
   git log origin/chore/agent-handoff --grep='^handoff: HO-.* codex->' --format='%H %cI %s' -n 1
   # Resume on this machine
   git log origin/chore/agent-handoff --grep='^handoff: HO-' --format='%H %cI %s' -n 1
   ```
   Read the selected record without checking out its branch:
   `git show <handoff-sha>:.agent-handoff/CURRENT.md`. Also read CURRENT.md and HISTORY.md at the
   records branch tip for later corrections. No matching record is not a successful resume;
   report it and use §7 to recover, never silently select a different sender.
4. Verify the named implementation commit is present on `origin` using
   `git branch -r --contains <impl-sha>`, and that the named remote implementation branch contains
   it (`git merge-base --is-ancestor <impl-sha> origin/<implementation-branch>` must return 0).
   A missing branch/commit requires recovery, not guessing. For old records, infer missing
   records-branch/type fields from Git and explain the result; the initial setup is metadata only.
5. Look for newer work separately: `git log <impl-sha>..origin/<implementation-branch>` and
   `git log <handoff-sha>..origin/chore/agent-handoff`. Check local checkpoints in both known
   worktrees. Newer verified work and owner instructions override older records.
6. Resume **product work in the implementation worktree**, on its tracking branch, fast-forward
   only. Read metadata through `git show` or the separate records worktree; do not copy it into
   the code branch. For metadata-only tasks, work on the records branch. Before starting any
   product task from a metadata-only handoff, create a clean branch/worktree from `origin/master`.
7. Read `CLAUDE.md` and authoritative design documents from the implementation branch; keep the
   latest records-branch protocol in context. Verify material record claims against source, and
   rerun relevant named tests. Report discrepancies. Do not use the stale product snapshot on
   the records branch as the current implementation.
8. Tell the owner what was verified, the task, and the next action, then continue. Lack of a PR
   or merge for handoff metadata is intentional, not unfinished product delivery.

## 5. Local checkpoint ("Checkpoint current work")

1. In the worktree being checkpointed, ensure LOCAL.md is ignored (use the per-clone exclude
   above on product branches). Collect branch, HEAD, ahead/behind, and staged/unstaged/untracked
   file names. Identify which implementation and records branches the checkpoint concerns.
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

- **Handoff isolation.** The owner requires this setup and all handoff records to stay off
  `master` permanently. Use `chore/agent-handoff` without merging it into product branches.
  Public branches are public; purging provides no privacy guarantee and requires separate,
  explicit authorization. Keep private context local or in separately approved private storage.

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
