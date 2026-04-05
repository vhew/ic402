# ic402

Motoko payment and service marketplace library for ICP canisters. [x402](https://www.x402.org/) charges, streaming sessions, encrypted content, paid services with coordinator pattern, cross-chain EVM settlement, agent discovery.

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
| **EIP-712 signing** | Generic typed data signing — DEX agent wallets, permits, any EIP-712 protocol |
| **5 EVM chains** | Base, Ethereum, Avalanche, Optimism, Arbitrum |
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

## API Reference

### Gateway

| Method | Description |
|--------|-------------|
| `requireAll(amount)` | Generate ICP + all EVM payment requirements |
| `settle(signature)` | Settle via ICRC-2 (ICP) or HTTPS outcall (EVM) |
| `offerSession(intent)` | Create session offer |
| `openSession(...)` | Deposit escrow, create session |
| `consumeVoucher(voucher)` | Verify + consume session voucher |
| `closeSession(caller, id)` | Settle consumed, refund remainder |
| `setPolicy(caller?, policy)` | Set spending policy |
| `issueGrant(...)` / `verifyGrant(grant)` | HMAC access grants |
| `startTimers<system>()` | Start background timers |
| `toStable()` / `loadStable(data)` | Upgrade persistence |

### ServiceRegistry (optional)

| Method | Description |
|--------|-------------|
| `registerService(caller, def)` | Register a paid service |
| `enableService(caller, id)` | Activate for purchases |
| `listServices(enabledOnly)` | Service discovery |
| `submitRequest(buyer, serviceId, params, receipt, callback?)` | Create a paid job |
| `claimJob(caller, jobId)` | Operator claims work |
| `submitResult(caller, jobId, result, proof?, actualCost?)` | Submit + auto-verify |
| `confirmJob(buyer, jobId)` | Buyer confirms (BuyerConfirm) |
| `disputeJob(buyer, jobId, reason)` | Buyer disputes |
| `expireJobs()` | Timer: refund stale jobs |
| `toStable()` / `loadStable(data)` | Upgrade persistence |

**Verification methods:** `#AutoSettle`, `#HashMatch`, `#BuyerConfirm`, `#ZkGroth16` (external Rust verifier canister).

### ContentStore (optional)

| Method | Description |
|--------|-------------|
| `put(id, mimeType, data)` | Encrypt + store |
| `get(id)` | Decrypt + retrieve |
| `list()` | Content metadata |

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
| `http402(requirements)` | Build HTTP 402 response |
| `http200Json(json)` / `http200(body, mimeType)` | Build HTTP 200 |
| `http202Json(json)` | Build HTTP 202 Accepted (async services) |
| `httpUpgrade()` | Signal upgrade to update call |
| `parseX402PaymentHeader(base64)` | Parse x402 v2 header |

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

## Known Limitations

- **EVM escrow is virtual accounting.** `EvmEscrowManager` tracks allocations in memory but does not query on-chain balances. The consuming canister should verify `totalAllocated + newDeposit` against the actual token balance before opening EVM sessions.
- **`forceCloseSession` has no library-level access control.** The consuming canister MUST wrap it with `assert(Principal.isController(msg.caller))` or equivalent before exposing it as a public endpoint.
- **Ed25519 library (`mo:ed25519`) is unaudited.** Used for session voucher verification. The library is functionally correct in testing but has not undergone a formal cryptographic audit.
- **`discoverAgents()` returns empty.** ERC-8004 IdentityRegistry contracts are deployed but registries are sparse — no real agent data to query yet.
- **Client-side budget tracking is advisory.** `BudgetConfig` in the TypeScript SDK is enforced client-side only. Real spending limits are enforced by the canister's `Policy` engine.
- **EVM payment verification depends on the DFINITY EVM RPC canister.** On local replicas, EVM settlement requires the prebuilt EVM RPC canister and internet access to reach testnet/mainnet RPC endpoints.

## License

[Apache 2.0](LICENSE)
