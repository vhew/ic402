# Changelog

## v1.0.0 — 2026-04-05

### Breaking Changes

- **X402Client removed**: Outbound x402 payments now use EvmSigner (canister signs) + client library (probes URL, broadcasts tx). The canister no longer makes EVM RPC outcalls for outbound operations, reducing cycles cost 40-85%.
- **Identity stripped to metadata**: `registerAgent()`, `getEvmNonce()`, `getFeeData()`, `buildRegisterCalldata()`, `parseAgentRegisteredEvent()` removed. Registration now uses `EvmSigner.signRegistration()` + client-side broadcast.
- **EvmSender is internal-only**: No longer exported from `lib.mo`. Used internally by Gateway for inbound settlement.
- **Client BudgetConfig removed**: Client-side budget tracking was advisory only (not enforceable by a compromised client). Canister-side SpendingPolicy is the enforcement point.
- **ServiceRegistry buyer parameter**: `submitRequest`, `confirmJob`, `disputeJob` now take `Principal` instead of `Text`.

### New Modules

- **EvmSigner** (`src/ic402/EvmSigner.mo`): Remote signing module — canister holds tECDSA key and signs; client handles all RPC/HTTP. Methods: `signTransaction`, `signErc20Transfer`, `signEthTransfer`, `signEip3009Authorization`, `signRegistration`, `signTypedData`.
- **ServiceRegistry** (`src/ic402/ServiceRegistry.mo`): Paid service marketplace coordinator. Canister escrows funds, assigns jobs to operators, verifies results (AutoSettle, HashMatch, BuyerConfirm, ZkGroth16), and settles payment. Full job lifecycle: Pending → Assigned → Submitted → Verified → Settled.
- **ZK Verifier** (`example/zk-verifier/`): Reference Rust canister implementing Groth16/BN254 verification via arkworks. ~392KB WASM, ~$0.005 per proof.

### New Exports

- `EvmSigner`: the only public EVM module (remote signing)
- `ServiceRegistry`: paid service marketplace
- `Eip712`: EIP-712 hashing utilities (domainSeparator, digest)
- `EvmAddress`: keccak256 hashing
- `EvmUtils`: ABI encoding, hex conversion

### Features

- **Generic EIP-712 signing** (`signTypedData`): Universal primitive for any EIP-712 protocol — DEX agent wallets (Hyperliquid, Vertex, Aevo), permit signatures, meta-transactions.
- **HTTP 202 Accepted**: Async service requests return 202 with poll URL. HTTP `/service/*` and `/job/*` routes added.
- **x402 v2 header**: 402 responses now include base64 `payment-required` header alongside JSON body.
- **Service pricing models**: Exact (fixed price), Upto (max with refund), Session (streaming).
- **Service verification methods**: AutoSettle, HashMatch (SHA-256), BuyerConfirm (dispute window), ZkGroth16 (inter-canister Groth16 proof verification).
- **Timer-based job expiry**: Stale jobs auto-refund. Terminal jobs GC'd after 24h.

### TypeScript Client (`@ic402/client`)

- **New `evm` module**: `probeX402`, `fetchX402`, `findPaymentOption`, `broadcastTransaction`, `pollReceipt`, `registerAgent`, `Ic402Error` with 11 classified error kinds and `retryable` flag.
- **Service methods**: `listServices()`, `submitServiceRequest()` (ICRC-2 auto-pay with nonce handling), `pollJobResult()`, `disputeJob()`.
- **EVM methods**: `sendErc20Transfer()`, `sendEthTransfer()`, `registerAgent()`.
- **Typed config**: `Ic402Identity` interface replaces `unknown`. Options object for `fetchX402`.
- **Fixes**: session publicKey encoding (Uint8Array), ICRC-2 approve fee buffer, EVM session authorization passthrough.

### MCP Server

- New tools: `list_services`, `submit_request`, `get_job_result`, `dispute_job`, `fetch_x402` (direct probe → sign → pay).
- ICRC-2 ledger IDL factory for auto-approval.
- 15s AbortController timeouts on HTTP requests.

### Security

- **C-1**: EVM session close leaves `#closing` (not `#closed`) when refund fails, preserving `recoverEscrow` path.
- **H-1**: `EvmSender` txInProgress lock serializes concurrent EVM transactions (prevents nonce desync).
- **H-2**: `forceCloseSession()` has WARNING doc — consuming canister MUST add access control.
- **H-5**: `recoverEscrow` restricted to unconsumed portion, always refunds to payer (removed arbitrary recipient).
- **H-6**: `ContentStore.decryptChunkData` returns `?Blob` — propagates auth failures instead of returning empty blobs.
- **M-1**: Revoked grants store timestamps, GC removes entries >7 days old (hourly timer).
- **M-2**: Policy rateLimitLog deletes empty keys after filtering.
- **M-4**: EIP-3009 validAfter/validBefore validated before expensive EVM outcall.
- **M-5**: `expireJobs()` also GCs terminal jobs >24h old.
- **M-6**: EIP-3009 nonce uses `Time.now()` nanoseconds (monotonic, survives upgrades).
- **M-8**: Client `parseAgentRegisteredEvent` checks topics[0] against keccak256 event signature.
- **CF-1**: Example canister restored to mainnet values; deploy scripts patch for local.

### Refactoring

- `Utils.mo`: extracted `isEvmNetwork()`, `extractChainId()`, `findLedger()` from Gateway/Sessions (~50 LOC dedup).
- `Policy.mo`: `warnIfInvalid()` validates invariants on `loadStable()`.
- Removed unused `ic-vetkeys` dependency.

### Testing

- **36 integration tests**: charges (ICP settlement), sessions, content, services, EVM signer, EIP-712, identity, HTTP gateway, ZK verifier, policy.
- **40 Motoko unit tests**: ServiceRegistry lifecycle, disputes, stable state round-trip, edge cases.
- **8 escrow unit tests**: subaccount derivation determinism, uniqueness, prefix isolation.
- **69 client unit tests**: fetchX402, services, polling, error classification, findPaymentOption.

### Demo

- 10-step interactive walkthrough: Configure, ADD Encrypted Content, SELL Content over x402, DELETE Content, SELL Services over x402, BUY over x402, Streaming Micropayments, Agent Identity, EIP-712 Delegate Signing, Policy + Summary.

### Tooling

- `@icp-sdk/icp-cli` upgraded 0.1.0 → 0.2.2 (fixes icp.yaml parse errors when run via pnpm).
- `icp.yaml` schema updated to v0.2.2. ZK verifier added to local environment.
- Setup/reset scripts always stop + clean before starting (port kill, cache purge, pocket-ic reset).

---

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
