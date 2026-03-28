# Changelog

## v0.1.5 — 2026-03-28

### Documentation

- Add `///` doc comments to all remaining public declarations across 13 internal modules (EvmRpc, Eip712, EvmVerify, Sessions, Policy, Nonce, Escrow, Grants, EvmEscrow, EvmSender, Utils, HttpHandler, Identity) — targets 100% mops documentation coverage.

### Project Structure

- Rename `integration/` → `integrations/` for consistency with engramx convention. Update all references in workspace config, package.json scripts, version.sh, docs, and example client.
- Untrack `deploy/deploy.sh` — was force-added but belongs to gitignored local-only tooling.

---

## v0.1.4 — 2026-03-28

### API

- Trim public API surface ~60% — only Gateway, ContentStore, Identity, X402Client, and HttpHandler exported from `lib.mo`. Internal modules (Sessions, Nonce, Escrow, Grants, Policy, EvmSender, EvmEscrow, EvmRpc, EvmAddress, Eip712) are no longer re-exported.
- Add `///` doc comments to all 44 public types and all exported APIs.

### Dependencies

- `ic` 2.1.0 → 3.2.0 (adds `is_replicated` field to HTTP outcalls)
- `test` 2.0.0 → 2.1.2

### Package Metadata

- Add `keywords` to `mops.toml` for registry discoverability
- Add CHANGELOG entry for mops release notes

---

## v0.1.3 — 2026-03-27

### Security Hardening

- **C-1**: `recoverEscrow` rejects when session not found (was auth bypass)
- **C-2**: Remove `Math.random()` fallback in EIP-3009 nonce generation
- **H-1**: Add session garbage collection to prevent unbounded memory growth
- **H-2**: Surface EVM address derivation errors in canister logs
- **H-3**: Inline expiry check in `consumeVoucher` (closes timer gap)
- **H-5**: Validate PKCS#8 structure in MCP PEM parsing
- **M-1**: Replace bare `assert()` with descriptive `Debug.trap()` messages
- **M-3**: Rate-limit session open attempts via policy engine
- **M-4**: Validate URL scheme and path traversal in client `fetchContent`
- **M-5**: Return error when EVM chain config missing (was silent default)
- **M-6**: Add Zod validators for EVM addresses/hashes/networks in MCP

### Improvements

- Update `ic` dependency 2.1.0 → 3.2.0 (add `is_replicated` to HTTP outcalls)
- Trim public API surface ~60% — only Gateway, ContentStore, Identity, X402Client, HttpHandler exported
- Add `///` doc comments to all public types and exported APIs
- Add `keywords` to `mops.toml` for registry discoverability
- `@ic402/client` npm package: add README, LICENSE, `files` field, `peerDependencies`, `engines`
- Deploy script: selective stages (`production publish mops`, `production publish npm`, `production canister`)
- Deploy script: auto git push and GitHub release creation

### Dependencies

- `ic` 2.1.0 → 3.2.0
- `test` 2.0.0 → 2.1.2
- Zero npm audit vulnerabilities

---

## v0.2.0 — 2026-03-24

### Standard x402 Compatibility (EIP-3009)

- **EIP-3009 payment settlement**: Standard x402 clients can now pay ic402 servers. The canister acts as its own facilitator, executing `transferWithAuthorization` on USDC contracts via tECDSA.
- **EIP-712 signature verification**: On-canister verification of typed-data signatures for EVM authorization (`Eip712.mo`).
- **x402 v1 response format**: HTTP 402 responses now emit standard `asset`, `payTo`, `maxAmountRequired`, and `extra` fields.
- **Base64 X-PAYMENT header**: Standard x402 header format (base64-encoded JSON) alongside legacy ic402 format.
- **On-canister EVM signing**: RLP encoding, ABI encoding, EIP-1559 transaction construction, and EC recovery — all in pure Motoko (`EvmUtils.mo`, `EvmSender.mo`, `EvmAddress.mo`).
- **Autonomous agent registration**: Canister signs and submits its own ERC-8004 registration tx on Base via tECDSA (`Identity.mo`). No external wallet needed.
- **EVM session deposits via EIP-3009**: Session deposits on EVM chains use `transferWithAuthorization` instead of direct transfers.
- **EVM session settlement**: Close settles consumed amount and refunds remainder via tECDSA-signed ERC-20 transfers.
- **Client SDK EIP-712 helpers**: TypeScript functions for building `TransferWithAuthorization` typed data and `X-PAYMENT` headers (`eip712.ts`).

### Breaking Changes

- **EVM charge settlement requires EIP-3009**: Legacy direct ERC-20 transfer + tx hash flow removed. EVM payments must now use `transferWithAuthorization` authorization signatures.
- **`consumedTxHashes` removed from stable state**: EIP-3009 nonce-based replay protection replaces tx hash tracking.
- **`PaymentSignature.authorization`**: New optional field for EIP-3009 data.
- **`ERC8004Config` expanded**: Now requires `ecdsaKeyName`, `registryAddress`, `chainId`, `evmRpcCanister`, `gasConfig`.
- **`register-agent.ts` removed**: Agent registration is now on-canister via `registerAgent()`.

### Security Fixes

- **C-2**: EVM transfer logs filtered by contract address in `EvmVerify.findTransferLog`
- **H-1**: Grant issuance requires initialized HMAC seed
- **H-2**: Nonces bound to network + token (not just amount)
- **C-1**: Nonce lock state persisted across upgrades

---

## v0.1.0 — 2026-03-23

Initial production release.

### Features

- **x402 charges**: One-shot ICRC-2 payment gating with nonce replay protection
- **Streaming sessions**: Escrow deposits with cumulative Ed25519-signed vouchers
- **Encrypted content store**: In-canister chunked storage with HMAC-bound access grants
- **ERC-8004 identity**: On-chain agent registration on Base via EVM RPC canister
- **Cross-chain settlement**: 5 EVM chains (Base, Ethereum, Avalanche, Optimism, Arbitrum) via EVM RPC canister
- **TypeScript client SDK** (`@ic402/client`): Budget enforcement, session management, content fetching
- **MCP integration**: Model Context Protocol server for AI agent access

### Security

18-finding audit resolved (3 CRITICAL, 5 HIGH, 10 MEDIUM):

- **C-1**: EVM transaction replay prevention (consumed tx hash set)
- **C-2**: HMAC-bound access grants (contentRef.id included in HMAC)
- **C-3**: Nonce-amount binding (prevents amount manipulation)
- **H-1**: Session close authorization (only payer can close)
- **H-2**: Nat64 overflow protection in voucher encoding
- **M-4**: JSON injection prevention via `escapeJsonString`
- **M-5**: Zero-delta voucher rejection
- **M-8**: Escrow recovery authorization (only session payer)
- **M-10**: JSON unescape in `extractJsonField`

### Breaking Changes

- `closeSession` now requires caller to be the session payer (H-1)
- Access grant HMAC now binds `contentRef.id` — grants from prior versions are invalid (C-2)
- `recoverEscrow` now requires caller authorization (M-8)

### Known Limitations

- `discoverAgents()` returns empty array — ERC-8004 registries are sparse, no real data to query yet
- Ed25519 library (`mo:ed25519`) is unaudited
