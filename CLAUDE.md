# ic402

Production-ready Motoko payment library for ICP canisters.
x402 charges, streaming sessions, encrypted content, cross-chain EVM settlement (5 chains), ERC-8004 agent identity on Base.
Source has mainnet values; deploy scripts patch to testnet for local development.

## Build & Test

```bash
pnpm install                    # install deps
pnpm build:client               # TypeScript client SDK
pnpm build:demo                 # MCP server + demo client
mops test                       # Motoko unit tests
pnpm demo                       # interactive demo (needs local replica)
pnpm setup:local                      # deploy locally (full setup)
# Hermetic EVM-outbound gate (no funded testnet) — after setup:local:
bash scripts/setup-evm-outbound.sh    # re-point example at the EVM-RPC mock
IC402_REQUIRE_EVM_OUTBOUND=1 pnpm exec vitest run test/evm-outbound.test.ts
```

## Key Files

- `src/ic402/` — Motoko library (Gateway, Nonce, EvmVerify, ContentStore, Policy, Identity, HttpHandler, Eip712, EvmUtils, EvmSender, EvmRpc, EvmEscrow, X402Client)
- `example/main.mo` — Example canister using the library
- `example/client/` — Interactive demo client
- `example/evm-rpc-mock/` — Scriptable EVM-RPC mock canister; drives the hermetic EVM-outbound CI gate (`scripts/setup-evm-outbound.sh` + `test/evm-outbound.test.ts`)
- `packages/client/` — TypeScript client SDK (@ic402/client)
- `integrations/mcp/` — MCP server for AI agent access
- `scripts/` — Dev tooling (setup, version bump, deployment)

## Linear handoff (coding agent)

You are the **ic402** coding agent. Work comes from Linear team **Engramx** (issue key `EGX`).

### Claim filter (required)
Only pick issues that have **all** of:
- label `coding-agent`
- label `repo:ic402`
- status **Todo**

Ignore: `needs-routing`, other `repo:*`, parent/umbrella issues, and anything already In Progress by someone else.

### Protocol
1. Set status **In Progress**.
2. Implement only this repo (`vhew/ic402`). Do not touch engramx / engramx-platform / engramx-workshop.
3. Stay inside the issue’s acceptance criteria — no invented scope.
4. Open a PR against the default branch.
5. Comment the Linear issue with the PR URL.
6. Set status **In Review** (not Done). Done is after human/ops merge.
7. If the issue is clearly wrong-repo: do **not** claim it. Comment `wrong-repo → suggest repo:…` and leave Todo / needs-routing.

### Definition of finished (required)
An issue is **NOT finished** until all three are true:

- **(a)** a GitHub PR is open against the default branch,
- **(b)** the Linear issue has a comment containing the PR URL,
- **(c)** the Linear issue status is **In Review**.

Until then, do not say “done”, “complete”, or “finished”, and never set status **Done** —
Done belongs to the human/ops merge, not to the coding agent.

Local commits are not delivery. A branch that exists only on this machine, or only on
`origin` with no PR, is unfinished work.

**If you cannot open the PR** — no push rights, auth failure, anything else — leave the issue
**In Progress**, report the blocker plainly, and say what is needed to unblock it. Do not
advance the status, and do not describe the work as done.

### Project hint
Prefer issues on Linear project **ic402** when listed.

Linear status is the done signal — not Slack or Discord.
