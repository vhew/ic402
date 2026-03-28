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
```

## Key Files

- `src/ic402/` — Motoko library (Gateway, Nonce, EvmVerify, ContentStore, Policy, Identity, HttpHandler, Eip712, EvmUtils, EvmSender, EvmRpc, EvmEscrow, X402Client)
- `example/main.mo` — Example canister using the library
- `example/client/` — Interactive demo client
- `packages/client/` — TypeScript client SDK (@ic402/client)
- `integrations/mcp/` — MCP server for AI agent access
- `scripts/` — Dev tooling (setup, version bump, deployment)
