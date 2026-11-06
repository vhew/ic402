# Resuming ic402 on a new machine

Do these steps once per machine, then resume with the command in step 6. Nothing here is secret.
Credentials stay in each tool's own login flow, never in this repository.

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
```

## 3. Development tools

The versions are pinned. The source of truth is `package.json` (`engines`, `packageManager`),
`mops.toml` (`[toolchain]`) and `.github/workflows/ci.yml`.

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
  from the repository root. It loads `CLAUDE.md` automatically.
- **Codex:** install it from the official docs (https://developers.openai.com/codex) and launch it
  from the repository root. It loads `AGENTS.md` automatically, and that file sends it to
  `CLAUDE.md` and the protocol.
- Each agent's private memory and settings stay on the old machine. Anything the work depends on
  must be in the repository; that is what the handoff records are for.

## 5. Find and check the handoff

`.agent-handoff/PROTOCOL.md` §4 is the procedure. In short:

```bash
git log --remotes=origin --grep='^handoff: HO-' --format='%h %cI %s%n    %D' -n 5
git show <handoff-sha>:.agent-handoff/CURRENT.md
git branch -r --contains <implementation-sha-from-the-record>
```

`.agent-handoff/LOCAL.md` (local checkpoints) does not travel between machines. Only formal
handoffs do.

## 6. Resume

Launch the agent in the repository root and say **"Resume on this machine"**, or "Resume from
Claude" / "Resume from Codex" when switching agents too. The agent checks the record against Git
and the source before continuing.
