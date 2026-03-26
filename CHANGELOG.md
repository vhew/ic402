# Changelog

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
