# Resuming ic402 on a new machine

Do these steps once per machine, then resume with the command in step 6. Nothing here is secret.
Credentials stay in each tool's own login flow, never in this repository.

**Owner policy:** `chore/agent-handoff` is the dedicated records branch and must never merge into
`master` or a product branch. This setup stays on that branch. It is public, not semi-private;
periodic purging cannot guarantee erasure and is never automatic. Private context belongs in
local-only or separately authorized private storage.

## 1. Accounts and access

- **GitHub:** you need an account with push rights to `vhew/ic402`. SSH works, as does HTTPS with
  a credential helper. If this machine uses more than one GitHub identity, give this repository
  its own SSH host alias and point `origin` at it (`git remote set-url origin git@<alias>:vhew/ic402.git`).
- **`gh` CLI** (optional; used for PRs and CI): run `gh auth login` with the same account. With
  several gh accounts, keep this one in its own config directory and set `GH_CONFIG_DIR` when
  working here.
- **Check access:** `git ls-remote origin HEAD` should print a SHA, and `gh auth status` should
  show the right account.

## 2. Clone

```bash
git clone git@github.com:vhew/ic402.git    # or https://github.com/vhew/ic402.git
cd ic402
git fetch origin --prune
git show origin/chore/agent-handoff:.agent-handoff/PROTOCOL.md
```

A fresh default-branch checkout does not contain this handoff setup. Read the protocol from the
remote branch as above. Keep code in this checkout and metadata in a separate worktree. In a
fresh clone with no local records branch/worktree, create it with:

```bash
git worktree add -b chore/agent-handoff ../ic402-handoffs origin/chore/agent-handoff
```

On an existing clone, inspect `git worktree list` and local branches first; reuse the records
worktree or attach the existing records branch, without resetting it. Create product task branches
from `origin/master` (or a verified clean implementation branch), never from the records branch.
Do not merge or copy this setup into the default branch merely to make agent discovery automatic.

## 3. Development tools

Run builds in the **implementation checkout**, not the records worktree. The latter contains an
old code snapshot. The versions below are setup-time hints; the current source of truth is
`package.json` (`engines`, `packageManager`), `mops.toml` (`[toolchain]`) and
`.github/workflows/ci.yml` on the implementation branch.

| Tool | Version | Install |
|---|---|---|
| Node.js | ≥ 22.22.1 (CI uses 22) | nvm, or `conda env create -f environment.yml` |
| pnpm | 10.34.9 | `corepack enable` (reads `packageManager`) |
| mops CLI | 3.5.1 | `npm i -g ic-mops@3.5.1` |
| moc, wasmtime | 2.1.0, 50.0.0 | installed by `mops install` from `mops.toml`; check with `mops toolchain bin moc` |
| icp-cli (local replica only) | 1.7.0 | `npm i -g @icp-sdk/icp-cli@1.7.0` |

```bash
pnpm install --frozen-lockfile
mops install
pnpm build:client && mops test      # the baseline: all Motoko suites pass (~1 min)
```

The replica suites need `pnpm setup:local` (see `CLAUDE.md`). They skip when no replica is
running. `deploy/` is local-only tooling holding real keys. It is never in Git; if this machine
needs it, the owner copies it over separately.

## 4. Coding agents

- **Claude Code:** install it from the official docs (https://code.claude.com/docs) and launch it
  from the records worktree for handoff discovery, where `CLAUDE.md` points to the protocol.
- **Codex:** install it from the official docs (https://developers.openai.com/codex) and launch it
  from the records worktree for handoff discovery, where `AGENTS.md` points to
  `CLAUDE.md` and the protocol.
- Each agent's private memory and settings stay on the old machine. Anything the work depends on
  must be in the public-safe records or separately approved private storage. Never copy private
  memory wholesale into this public branch.

## 5. Find and check the handoff

`.agent-handoff/PROTOCOL.md` §4 is the procedure. In short:

```bash
git log origin/chore/agent-handoff --grep='^handoff: HO-' --format='%H %cI %s' -n 1
git show <handoff-sha>:.agent-handoff/CURRENT.md
git branch -r --contains <implementation-sha-from-the-record>
```

`.agent-handoff/LOCAL.md` (local checkpoints) does not travel between machines. Only formal
handoffs do. Before writing a checkpoint on a product branch, exclude that path in the clone's
local `info/exclude` (find it with `git rev-parse --git-path info/exclude`) and verify it with
`git check-ignore .agent-handoff/LOCAL.md`. Do not modify tracked product files for that exclusion.
For a sender-specific resume, use the sender-filtered commands in protocol §4 before limiting
results. Read metadata from the records branch; verify the separate implementation branch/SHA.

## 6. Resume

Start the agent in the records worktree and say **"Resume on this machine"**, or "Resume from
Claude" / "Resume from Codex" when switching agents too. It reads the latest protocol and then
resumes product work in the implementation checkout. Metadata-only work stays on the records branch.

If starting in a product checkout, provide this explicit startup prompt (the handoff entry points
are intentionally absent there):

> Fetch origin and read `git show origin/chore/agent-handoff:.agent-handoff/PROTOCOL.md`, then
> follow its "Resume on this machine" procedure. Keep the records branch and all handoff setup
> out of master and product branches. Read metadata via git show or the separate records worktree;
> verify and continue code work in the named implementation checkout. Do not merge or copy the
> handoff setup into the code branch.

For privacy, use private storage; deleting a public branch is not a privacy boundary. No bootstrap
or resume command authorizes deleting branches, purging records, or rewriting history.
