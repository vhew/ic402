# Contributing to ic402

## Prerequisites

- [ICP SDK](https://internetcomputer.org/docs/building-apps/getting-started/install) — `icp` CLI for building and deploying canisters
- [mops](https://mops.one) — Motoko package manager (like npm for Motoko)
- [Node.js](https://nodejs.org/) >= 22
- [pnpm](https://pnpm.io/) >= 9
- [Foundry](https://book.getfoundry.sh/getting-started/installation) — for Solidity contract development (optional)

## Setup

```bash
git clone https://github.com/vhew/ic402.git && cd ic402
pnpm setup    # installs deps, starts local replica, deploys canisters, funds test accounts
```

This starts a local ICP replica, deploys the example canister and a local ckUSDC ledger, creates test identities, and funds them with ckUSDC.

## Build

```bash
mops test                 # Motoko unit tests
icp build                 # build the canister
pnpm build:client         # TypeScript client SDK
pnpm build:mcp-client     # MCP server + demo client
pnpm demo                 # interactive demo (requires local replica)
```

## Project Layout

```
src/ic402/          Motoko library — the core package published to mops
example/            Example canister using the library
packages/client/    TypeScript SDK published to npm as @ic402/client
integration/mcp/    MCP server for AI agent access
integration/mcp-client/  Interactive demo client
contracts/src/      IdentityRegistry.sol (ERC-8004 on Base)
test/               Motoko unit tests + TypeScript integration tests
scripts/            Dev tooling (setup, register-agent, version bump)
deploy/             Deployment scripts and environment configs (gitignored)
```

## Making Changes

1. Create a branch from `master`
2. Make your changes
3. Run `mops test` — all Motoko tests must pass
4. Run `pnpm build:mcp-client` — all TypeScript must compile
5. Run `icp build` — canister must build
6. If you changed Solidity: `cd contracts && forge test`
7. Test the demo if you changed anything user-facing: `pnpm demo`

## Code Style

- Motoko: no enforced formatter — follow existing patterns in `src/ic402/`
- TypeScript: `pnpm lint` (ESLint) and `pnpm format:check` (Prettier)
- Solidity: standard Foundry conventions

## Key Conventions

- **Mainnet values in source** — `example/main.mo` contains mainnet chain IDs, USDC addresses, and ledger principals. Deploy scripts patch these to testnet for local development. Do not commit testnet values to source.
- **Stable state** — every module with persistent state has `toStable()` / `loadStable()` methods. If you add state, add these methods.
- **No secrets in source** — private keys, PEM files, and `.env.development` are gitignored. Use `.env.example` as a template.

## Tests

| Type | Location | Run with |
|------|----------|----------|
| Motoko unit tests | `test/*.test.mo` | `mops test` |
| TypeScript integration | `test/integration.test.ts` | `pnpm test:integration` (needs local replica) |
| Solidity | `contracts/test/*.t.sol` | `cd contracts && forge test` |

## Pull Requests

- Keep PRs focused — one concern per PR
- Update tests if you change behavior
- If you change the Motoko library API, update `packages/client/src/types.ts` to match
- If you change the example canister's Candid interface, run `bash scripts/gen-did.sh`

## ICP Concepts for Non-ICP Developers

| Term | What it means |
|------|---------------|
| **Canister** | A smart contract on ICP. Runs WebAssembly, has persistent memory, serves HTTP. |
| **ICRC-2** | ICP's token standard with approve/transferFrom (like ERC-20 approve). |
| **tECDSA** | Threshold ECDSA — the canister derives a native secp256k1 key without holding a private key. Used to get an EVM address. |
| **HTTPS outcall** | Canisters can make outbound HTTP requests to external APIs (like EVM RPC nodes). |
| **Stable memory** | Persistent storage that survives canister upgrades. |
| **HTTP gateway** | ICP infrastructure that routes HTTP requests to canisters. Enables `https://<id>.icp0.io`. |
| **mops** | Motoko package manager. `mops add ic402` is like `npm install`. |
| **Candid** | ICP's interface description language (like ABI for Ethereum). `.did` files define the canister API. |

## License

By contributing, you agree that your contributions will be licensed under the [Apache 2.0](LICENSE) license.
