# ic402

Production-ready Motoko payment library for ICP canisters.
x402 charges, streaming sessions, encrypted content, cross-chain EVM settlement (5 chains), ERC-8004 agent identity on Base.
Source has mainnet values; deploy scripts patch to testnet for local development.

## Build & Test

```bash
pnpm install                    # install deps
pnpm build:client               # TypeScript client SDK
pnpm build:mcp-client           # MCP server + demo client
mops test                       # Motoko unit tests
pnpm demo                       # interactive demo (needs local replica)
./deploy/deploy.sh              # deploy locally
./deploy/deploy.sh --production # deploy to mainnet
```

## Key Files

- `src/ic402/` — Motoko library (Gateway, Nonce, EvmVerify, ContentStore, Policy, Identity, HttpHandler)
- `example/main.mo` — Example canister using the library
- `packages/client/` — TypeScript client SDK (@ic402/client)
- `integration/mcp/` — MCP server for AI agent access
- `integration/mcp-client/` — Interactive demo client
- `deploy/` — Deployment scripts and configs (gitignored except examples)
- `scripts/` — Dev tooling (setup, register-agent, version bump)
