# ic402

Motoko payment and service marketplace library for ICP canisters. [x402](https://www.x402.org/) charges, streaming sessions, encrypted content, paid services with a coordinator pattern, multi-token EVM settlement across 5 chains, and ERC-8004 agent identity on Base.

## Three modes

1. **Content** — Upload encrypted blobs, gate with x402, deliver on payment
2. **Charges** — Synchronous paid API calls (HTTP 402 → pay → 200)
3. **Services** — Async coordinator: canister escrows funds, operator computes off-chain, canister verifies and settles

## Quick start

```bash
mops add ic402
```

```motoko
import Ic402 "mo:ic402";
import Principal "mo:base/Principal";

persistent actor MyService {
  transient let gate = Ic402.Gateway(
    {
      recipient = { owner = Principal.fromActor(MyService); subaccount = null };
      tokens = [{
        ledger = Principal.fromText("xevnm-gaaaa-aaaar-qafnq-cai"); // ckUSDC
        symbol = "ckUSDC"; decimals = 6;
      }];
      evmChains = [];
      evmRpcCanister = null;
      ecdsaKeyName = null;
      nonceExpirySeconds = null;
    },
    Principal.fromActor(MyService),
  );

  // Charge for a service call
  public shared func search(query : Text, sig : ?Ic402.PaymentSignature) : async {
    #paymentRequired : [Ic402.PaymentRequirement];
    #ok : Text;
  } {
    switch (sig) {
      case (null) { #paymentRequired(gate.requireAll(1_000)) };
      case (?s) {
        switch (await gate.settle(s)) {
          case (#ok(_)) { #ok("Results for: " # query) };
          case (_) { #paymentRequired(gate.requireAll(1_000)) };
        };
      };
    };
  };

  var stableGateway : ?Ic402.StableGatewayState = null;
  do { switch (stableGateway) { case (?d) { gate.loadStable(d) }; case (null) {} } };
  system func preupgrade() { stableGateway := ?gate.toStable() };
  system func postupgrade() { stableGateway := null };
  gate.startTimers<system>();
};
```

See [`example/main.mo`](example/main.mo) for the full working example with all features.

## Architecture

```
┌─────────────────────────────────────────────────────────┐
│                      Your Canister                       │
│                                                          │
│  ┌──────────┐  ┌──────────┐  ┌────────────────────┐    │
│  │  Charge  │  │ Session  │  │  Service Registry  │    │
│  │  (x402)  │  │ (Escrow +│  │  (Jobs, Verify,    │    │
│  │          │  │ Vouchers)│  │   Settle)           │    │
│  └────┬─────┘  └────┬─────┘  └────────┬───────────┘    │
│       │              │                 │                 │
│  ┌────▼──────────────▼─────────────────▼─────────────┐  │
│  │             Settlement (dual-chain)               │  │
│  │  ICP:  ICRC-2 transfer_from                       │  │
│  │  EVM:  EVM RPC canister → getTransactionReceipt   │  │
│  └───────────────────────────────────────────────────┘  │
│                                                          │
│  ┌ ─ ─ ─ ─ ─ ─ ─ ─ ┐  ┌ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ┐  │
│  │ContentStore (opt)│  │EvmSigner + Identity (opt)│  │
│  │Encrypted storage │  │Remote signing + ERC-8004 │  │
│  └ ─ ─ ─ ─ ─ ─ ─ ─ ┘  └ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ┘  │
└─────────────────────────────────────────────────────────┘
```

### Payment flows

**x402 charge over HTTP:**
```
Client → GET /content/x → 402 (ICP + EVM payment options)
Client → pay USDC (any chain)
Client → GET + X-PAYMENT header → 200 + content
```

**Streaming sessions:** deposit once → stream Ed25519 vouchers × N → close (settle + refund). 2 on-chain txns for any number of calls.

**Paid services (coordinator):**
```
Buyer ──[pay]──> Canister ──[assign]──> Your Client
                    │                      │
                    │ escrow                │ compute off-chain
                    │                      │
                 [verify] <──[result+proof]─┘
                    │
              [settle payment]
              [refund remainder to buyer]
```

### EVM: remote signing

For outbound EVM operations (paying external x402 APIs, transfers, agent registration), the canister signs with tECDSA and the client handles RPC. This eliminates EVM RPC calls from the canister, reducing cycles 40-85%.

```
Client probes URL → canister signs → client retries with payment header
Client provides nonce+gas → canister signs tx → client broadcasts
```

## Features

| Feature | Description |
|---------|-------------|
| **x402 charges** | Standard HTTP 402, works with any x402 client |
| **Streaming sessions** | Escrow + Ed25519 vouchers, 5,000x cheaper than per-call |
| **Paid services** | Coordinator pattern: escrow, assign, verify (ZK/hash/buyer), settle |
| **Cross-rail settlement** | Marketplace jobs and streaming sessions settle/refund on their native rail — ICP from the pool, or on-chain to the EVM payout address (confirmed broadcast) |
| **EIP-712 signing** | Generic typed data signing — DEX agent wallets, permits, any EIP-712 protocol |
| **5 EVM chains** | Base, Ethereum, Avalanche, Optimism, Arbitrum — multiple tokens per chain, settlement keyed to the paid asset |
| **Remote signing** | Canister signs, client broadcasts — no EVM RPC dependency for outbound |
| **Encrypted content** | ChaCha20-Poly1305 at rest, 3 delivery patterns |
| **ZK verification** | Groth16/BN254 via reference Rust canister (~$0.005, 100-1000x cheaper than Ethereum) |
| **Policy engine** | Per-caller limits, rate limiting, session caps, daily budgets |
| **Agent discovery** | ERC-8004 on Base for cross-chain service registration |

## Why ICP

An ICP canister replaces the HTTP server, the wallet, the escrow, and the payment processor. ic402 makes this a one-line import.

- **HTTPS outcalls** — verify EVM payments directly, no oracle or bridge
- **tECDSA** — native EVM address, remote signing for outbound operations
- **HTTP serving** — canister IS the server, standard x402 responses
- **Persistent state** — escrow, jobs, encrypted content survive upgrades
- **Coordinator model** — the canister IS the smart contract, no external escrow needed

## Costs

Costs are bimodal — everything is cheap except signing **and** broadcasting an EVM transaction.

| Operation | Net cost |
|-----------|----------|
| x402 verify / 402 / content delivery | trivial (query, no outcall) |
| ICP settle (ICRC‑2) | ~10–500M cycles (≈ <$0.001) |
| Session voucher | trivial (Ed25519, in‑canister) — the 5,000× lever |
| EVM settle (sign + broadcast + confirm) | **~17B cycles** local / ~40–80B mainnet est. (≈ $0.02–0.10) + EVM gas |

Per‑call EVM settle is **underwater below ~$0.05–0.10** — use the ICP rail or sessions for micropayments. Measured numbers, the cycle buffer to hold, and rail‑selection guidance: **[docs/costs-and-rails.md](docs/costs-and-rails.md)**.

## Security

The money paths are sound — recipient binding, exact `value == amount`, single‑use nonces, confirm‑before‑deliver. But two things you must know before deploying with real funds:

- **The library is not secure‑by‑default.** Four access‑control checks (policy‑mutation auth, roster redaction, cross‑resource underpayment, content gating) live only in [`example/main.mo`](example/main.mo) — copy them or inherit a price‑bypass / roster‑leak / content‑leak.
- **One trust root.** Every admin/signer/recovery power is `Principal.isController`, so a single stolen controller key = total EVM drain + arbitrary signing.

Read **[docs/security-model.md](docs/security-model.md)** (integration checklist + key‑custody guidance) before going to mainnet.

## Demo

```bash
git clone https://github.com/vhew/ic402.git && cd ic402
pnpm setup:local    # install, start replica, deploy, fund
pnpm demo           # interactive walkthrough (10 steps)
```

<details>
<summary>Demo steps</summary>

1. **Configure** — connect, derive tECDSA EVM address
2. **ADD Encrypted Content** — upload, encrypt at rest
3. **SELL Content over x402** — hit paywall, pay with ICP or EVM, receive content
4. **DELETE Content** — lifecycle management
5. **SELL Services over x402** — register service, buyer pays, your client computes, canister verifies (ZK/auto), settles
6. **BUY over x402** — canister signs, client pays external API (GoldRush)
7. **Streaming Micropayments** — sessions with 5,000x settlement reduction
8. **Agent Identity** — ERC-8004 on Base
9. **EIP-712 Delegate Signing** — generic typed data signing for DEX agent wallets (Hyperliquid, Vertex, Aevo)
10. **Policy + Summary** — dual-sided spending limits

</details>

## Testing

| Command | Covers |
|---------|--------|
| `mops test` | Motoko unit suites (16: gateway, sessions, escrow, serviceregistry, evmverify, evmsender, evmescrow, evmaddress, evmutils, eip712, nonce, policy, grant, contentstore, httphandler, utils) |
| `pnpm test:client` | TypeScript client SDK (`@ic402/client`, vitest) |
| `pnpm exec vitest run` | Root vitest — MCP guards + SSRF/security units (source-imported), plus the integration suite |
| `pnpm test:integration` | Replica-backed end-to-end (needs `pnpm setup:local`) |
| `bash scripts/setup-evm-outbound.sh` then `IC402_REQUIRE_EVM_OUTBOUND=1 pnpm exec vitest run test/evm-outbound.test.ts` | Hermetic EVM-outbound rail (sign → broadcast → confirm/park) against a scriptable EVM-RPC mock — no funded testnet |

The replica-backed suites return early (green) when their fixture isn't reachable. CI enforces them in dedicated jobs: `test-integration` runs with `IC402_REQUIRE_REPLICA=1`, and `test-evm-outbound` deploys the EVM-RPC mock and runs with `IC402_REQUIRE_EVM_OUTBOUND=1`, so a missing fixture is a hard failure rather than a silent skip.

## API Reference

### Gateway

| Method | Description |
|--------|-------------|
| `requireAll(amount)` | Generate ICP + all EVM payment requirements |
| `settle(signature, expectedAmount?)` | Settle via ICRC-2 (ICP) or HTTPS outcall (EVM); `expectedAmount` binds the on-chain amount on the facilitator path |
| `verifyPayment(signature, expectedAmount, payTo, asset)` | Off-chain x402 verify verdict (`{isValid, invalidReason?, payer?}`) — no nonce, no broadcast, EVM only |
| `offerSession(intent)` | Create session offer |
| `openSession(...)` | Deposit escrow, create session |
| `consumeVoucher(voucher)` | Verify + consume session voucher |
| `closeSession(caller, id)` | Settle consumed, refund remainder |
| `setPolicy(caller?, policy)` | Set spending policy |
| `setEvmChains(chains)` / `getEvmChains()` | Swap the accepted EVM chain/token set at runtime (e.g. Base Sepolia ↔ Base mainnet) — no redeploy; open sessions drain on their original chains. Transient: persist your choice consumer-side and re-apply after upgrade |
| `getGlobalPolicy()` | Read back the live global spending policy (example exposes it as the `getPolicyConfig` query) |
| `issueGrant(...)` / `verifyGrant(caller, grant)` | HMAC access grants (non-transferable — `caller` must equal `grant.grantee`) |
| `startTimers<system>()` | Start background timers |
| `toStable()` / `loadStable(data)` | Upgrade persistence |

### ServiceRegistry (optional)

| Method | Description |
|--------|-------------|
| `registerService(caller, def)` | Register a paid service |
| `enableService(caller, id)` | Activate for purchases |
| `listServices(enabledOnly)` | Service discovery |
| `submitRequest(buyer, serviceId, params, receipt, callback?)` | Create a paid job (`buyer : Text` — principal for ICP, 0x address for EVM) |
| `claimJob(caller, jobId)` | Operator claims work |
| `submitResult(caller, jobId, result, proof?, actualCost?)` | Submit + auto-verify |
| `confirmJob(buyer, jobId)` | Buyer confirms (BuyerConfirm) |
| `disputeJob(buyer, jobId, reason)` | Buyer disputes |
| `resolveDispute(jobId, refundBuyer)` | Admin: settle to operator or refund buyer (gate access) |
| `expireJobs()` | Timer: refund stale/disputed jobs |
| `toStable()` / `loadStable(data)` | Upgrade persistence |

Funds are custodied at the platform recipient account; `settleJob` pays the operator and refunds the buyer from there.

**Verification methods:** `#AutoSettle`, `#HashMatch`, `#BuyerConfirm`, `#ZkGroth16` (external Rust verifier canister).

### ContentStore (optional)

| Method | Description |
|--------|-------------|
| `startTimers<system>()` | Seed the encryption key from canister randomness (call once after deploy) |
| `initExternalSeed(seed)` | Manually seed the key (alternative to `startTimers`) |
| `put(id, mimeType, data)` | Encrypt + store |
| `get(id)` | Decrypt + retrieve |
| `list()` | Content metadata |

> **Seeding is required.** Writes trap until the master key is seeded with canister
> randomness (`startTimers()` or `initExternalSeed(await raw_rand())`). The key is then
> persisted across upgrades. This replaces the v1 deterministic key derived from the
> (public) canister principal.

### EvmSigner (optional)

| Method | Description |
|--------|-------------|
| `signTypedData(domainSep, structHash)` | **Sign arbitrary EIP-712 typed data** (DEX agents, permits, any protocol) |
| `signErc20Transfer(...)` | Sign ERC-20 tx (client broadcasts) |
| `signEthTransfer(...)` | Sign ETH tx (client broadcasts) |
| `signEip3009Authorization(...)` | Sign x402 payment header |
| `signRegistration(...)` | Sign ERC-8004 registration tx |
| `getEvmAddress()` | Canister's tECDSA-derived EVM address |

### Eip712 (hashing utilities)

| Method | Description |
|--------|-------------|
| `domainSeparator(name, version, chainId, contract)` | Build EIP-712 domain separator |
| `digest(domainSep, structHash)` | Compute EIP-712 message digest |

### EvmAddress / EvmUtils (crypto primitives)

| Method | Description |
|--------|-------------|
| `EvmAddress.keccak256(bytes)` | Keccak-256 hash |
| `EvmAddress.keccak256Text(text)` | Keccak-256 of UTF-8 string |
| `EvmUtils.abiEncodeUint256(n)` | ABI encode a uint256 |
| `EvmUtils.hexToBytes(hex)` / `bytesToHex(bytes)` | Hex conversion |

These primitives enable consumers to build EIP-712 messages for any protocol (Hyperliquid, Vertex, Aevo, ERC-2612 permits) and sign them with the canister's tECDSA key.

### Identity (optional)

| Method | Description |
|--------|-------------|
| `getCard()` | Agent card metadata |
| `getEvmAddress()` | Canister's EVM address via tECDSA |

### HttpHandler

| Method | Description |
|--------|-------------|
| `http402(requirements, resourceUrl)` | Build HTTP 402 response (x402 v2 `PaymentRequired`) |
| `paymentRequiredJson(requirements, resourceUrl, errorMsg?)` | Render the v2 `PaymentRequired` JSON object |
| `http402WithSettlement(settlementJson)` | 402 carrying a v2 `SettlementResponse` (settlement failure on a paid request) |
| `settlementResponseJson(success, txHash?, network, payer, amount, errorReason?)` | Render the v2 `SettlementResponse` (emitted in `PAYMENT-RESPONSE`) |
| `verifyResponseJson(isValid, invalidReason?, payer?)` | Render the facilitator `POST /verify` response |
| `discoveryItemJson(resourceUrl, resType, acceptsJson)` | One entry in the `GET /discovery/resources` listing |
| `http200Json(json)` / `http200(body, mimeType)` | Build HTTP 200 |
| `http202Json(json)` | Build HTTP 202 Accepted (async services) |
| `httpUpgrade()` | Signal upgrade to update call |
| `parseX402PaymentHeader(base64)` | Parse x402 v2 header |

### x402 facilitator (self-hosted)

The canister IS the facilitator — it advertises and settles its own payments, no third party. The example ([`example/main.mo`](example/main.mo)) wires the standard v2 facilitator endpoints over HTTP:

| Endpoint | Description |
|----------|-------------|
| `GET /supported` | Advertise the `(x402Version, scheme, network)` kinds it can settle + signer address (`Gateway.supportedJson`) |
| `POST /verify` | Off-chain authorization verdict (`Gateway.verifyPayment` → `verifyResponseJson`) |
| `POST /settle` | Broadcast + settle on-chain (`Gateway.settle` → `settlementResponseJson`) |
| `GET /discovery/resources` | List paid resources with their v2 `accepts[]` (Bazaar discovery, non-minting) |

See [`docs/x402-compliance.md`](docs/x402-compliance.md) for the full v2 conformance status of the EVM rail.

## Project structure

```
src/ic402/               Motoko library (published to mops)
  Gateway.mo             Charges, settlement, sessions, policy
  ServiceRegistry.mo     Paid services: jobs, verification, settlement
  EvmSigner.mo           Remote EVM + EIP-712 signing (client broadcasts)
  Eip712.mo              EIP-712 typed data hashing (domain separators, digests)
  EvmAddress.mo          EVM address derivation + keccak256
  EvmUtils.mo            ABI encoding, hex conversion, byte utilities
  EvmSender.mo           EVM execution (internal, for inbound settlement)
  HttpHandler.mo         x402 HTTP response helpers
  ContentStore.mo        Encrypted blob storage (optional)
  Identity.mo            ERC-8004 agent metadata (optional)
  Types.mo               Shared types
example/                 Example canister + interactive demo
  main.mo                Reference implementation (all features, 10-step demo)
  client/                Interactive demo client
  zk-verifier/           Reference Groth16 verifier (Rust, optional)
  evm-rpc-mock/          Scriptable EVM-RPC mock (hermetic EVM-outbound tests)
packages/client/         TypeScript SDK (@ic402/client)
integrations/mcp/        MCP server (@ic402/mcp)
```

## EIP-712 Signing (DEX Integration)

ic402 provides a generic `signTypedData` primitive for any protocol using EIP-712 typed data signatures. This is the building block for:

- **Hyperliquid** agent wallet registration + phantom agent order signing
- **Vertex** linked signer + order signing
- **Aevo** signing key registration + order signing
- **ERC-2612** permit signatures for gasless token approvals
- **Any EIP-712 protocol** — the canister signs, your client submits

```motoko
// Build domain separator and struct hash client-side (keccak256 + ABI encoding)
// Only the signing call goes to the canister
let result = await signer.signTypedData(domainSeparator, structHash);
// → { signature, signer, digest, v, r, s }
```

The consuming canister (e.g., EngramX) computes EIP-712 messages for the target protocol and calls `signTypedData` for the tECDSA signature. ic402 provides the crypto primitives (`Eip712`, `EvmAddress.keccak256`, `EvmUtils`), the consumer provides the protocol-specific message formatting.

## ZK Verification

For services requiring trustless verification, deploy a Groth16 verifier canister alongside your ic402 canister. See [`example/zk-verifier/`](example/zk-verifier/) for a reference implementation using arkworks.

- Cost: ~$0.005 per Groth16 verification (100-1000x cheaper than Ethereum)
- The ic402 library defines the `ZkVerifierActor` interface; you provide the verifier canister
- Test fixtures included: proof + verification key for circuit "x² = 25, x = 5"

## Contributing

Dev setup, project layout, and conventions: **[CONTRIBUTING.md](CONTRIBUTING.md)**. Cutting a
release — version bump, the stable-schema gate, publishing to mops + npm: **[RELEASING.md](RELEASING.md)**.

## License

[Apache 2.0](LICENSE)
