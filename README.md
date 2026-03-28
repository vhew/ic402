# ic402

Drop-in Motoko payment library for ICP canisters. [x402](https://www.x402.org/) charges, streaming sessions, encrypted content, cross-chain EVM settlement, agent discovery.

## Quick start

```bash
mops add ic402
```

```motoko
import Ic402 "mo:ic402";
import Principal "mo:base/Principal";
import Text "mo:base/Text";

persistent actor MyService {
  // 1. Create a Gateway with your payment config
  transient let gate = Ic402.Gateway(
    {
      recipient = { owner = Principal.fromActor(MyService); subaccount = null };
      tokens = [{
        ledger = Principal.fromText("xevnm-gaaaa-aaaar-qafnq-cai"); // ckUSDC
        symbol = "ckUSDC"; decimals = 6;
      }];
      evmChains = [];       // set to [] for ICP-only, or add EVM chains (see example/)
      evmRpcCanister = null; // null = mainnet default
      ecdsaKeyName = null;   // null = no EVM address derivation (ICP-only)
      nonceExpirySeconds = null; // null = 5 minutes
    },
    Principal.fromActor(MyService),
  );

  // 2. Charge for a service call
  public shared func search(query : Text, sig : ?Ic402.PaymentSignature) : async {
    #paymentRequired : [Ic402.PaymentRequirement];
    #ok : Text;
  } {
    switch (sig) {
      case (null) { #paymentRequired(gate.requireAll(1_000)) }; // $0.001 USDC
      case (?s) {
        switch (await gate.settle(s)) {
          case (#ok(_)) { #ok("Results for: " # query) };
          case (_) { #paymentRequired(gate.requireAll(1_000)) };
        };
      };
    };
  };

  // 3. Serve x402 over HTTP
  transient let Http = Ic402.HttpHandler;

  public query func http_request(request : Ic402.HttpRequest) : async Ic402.HttpResponse {
    let path = Http.getPath(request.url);
    if (path == "/") { return Http.http200Json("{\"name\":\"MyService\"}") };
    switch (Http.getHeader(request.headers, "x-payment")) {
      case (?_) { Http.httpUpgrade() };               // has payment → settle in update call
      case (null) { Http.http402(gate.requireAll(1_000)) }; // no payment → 402
    };
  };

  public shared func http_request_update(request : Ic402.HttpRequest) : async Ic402.HttpResponse {
    let header = switch (Http.getHeader(request.headers, "x-payment")) {
      case (?p) { p }; case (null) { return Http.httpError(400, "Missing payment") };
    };
    let sig = switch (Http.parseX402PaymentHeader(header)) {
      case (?s) { s };
      case (null) { switch (Http.parsePaymentHeader(header)) {
        case (?s) { s }; case (null) { return Http.httpError(400, "Invalid payment") };
      }};
    };
    switch (await gate.settle(sig)) {
      case (#ok(_)) { Http.http200Json("{\"result\":\"paid content\"}") };
      case (_) { Http.httpError(402, "Payment failed") };
    };
  };

  // 4. Stable state (required for upgrade survival)
  var stableGateway : ?Ic402.StableGatewayState = null;
  do { switch (stableGateway) { case (?d) { gate.loadStable(d) }; case (null) {} } };
  system func preupgrade() { stableGateway := ?gate.toStable() };
  system func postupgrade() { stableGateway := null };

  gate.startTimers<system>();
};
```

See [`example/main.mo`](example/main.mo) for the full working example with sessions, content store, x402 client, and ERC-8004 identity.

## What a 402 looks like

```bash
curl https://<canister-id>.raw.icp0.io/search?q=payments
```

```json
{
  "x402Version": 1,
  "accepts": [
    { "scheme": "exact", "network": "icp:1", "asset": "xevnm-gaaaa-aaaar-qafnq-cai", "maxAmountRequired": "1000", "payTo": "<canister>" },
    { "scheme": "exact", "network": "eip155:8453", "asset": "0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913", "maxAmountRequired": "1000", "payTo": "0x<canister-evm-address>" }
  ]
}
```

Client picks ICP ckUSDC or EVM USDC. Same price, same API.

## Features

- **x402 charges** — standard HTTP 402, works with any x402 client
- **Streaming sessions** — escrow + Ed25519 vouchers, 5,000x cheaper than per-call settlement
- **5 EVM chains** — Base, Ethereum, Avalanche, Optimism, Arbitrum via HTTPS outcalls
- **Encrypted content** — SHA-256-CTR at rest, 3 delivery patterns (in-canister, asset canister, external)
- **x402 client** — canister pays external x402 APIs autonomously via tECDSA
- **Policy engine** — per-caller limits, rate limiting, session caps, daily budgets
- **Agent discovery** — ERC-8004 on Base for cross-chain service registration

## Why ICP

An ICP canister replaces the HTTP server, the wallet, and the payment processor. ic402 makes this a one-line import.

- **HTTPS outcalls** — verify EVM payments directly, no oracle or bridge
- **tECDSA** — native EVM address, no external wallet
- **HTTP serving** — canister IS the server, standard x402 responses
- **Stable memory** — encrypted content survives upgrades

<details>
<summary>Comparison with other x402 implementations</summary>

| | x402-icp | Anda Facilitator | **ic402** |
|---|---|---|---|
| Charge (one-time) | Yes | Yes | **Yes** |
| HTTP 402 serving | External server | External server | **Canister serves HTTP** |
| Streaming sessions | No | No | **Yes — 5,000x cheaper** |
| Cross-chain (5 EVM) | No | No | **Yes — HTTPS outcalls** |
| Encrypted content | No | No | **Yes** |
| Policy engine | No | No | **Yes — dual-sided** |
| Agent discovery | No | No | **Yes — ERC-8004 on Base** |
| Drop-in library | No | No | **Yes — one import** |

</details>

## Architecture

```
┌──────────────────────────────────────────────────────┐
│                     Your Canister                     │
│                                                       │
│  import Ic402 "mo:ic402"                              │
│                                                       │
│  ┌──────────┐  ┌──────────┐  ┌───────────────────┐   │
│  │  Charge  │  │ Session  │  │  Policy Engine    │   │
│  │  (x402)  │  │ (Escrow +│  │  (limits, rates,  │   │
│  │          │  │ Vouchers)│  │   daily caps)     │   │
│  └────┬─────┘  └────┬─────┘  └───────┬───────────┘   │
│       │              │               │                │
│  ┌────▼──────────────▼───────────────▼────────────┐   │
│  │           Settlement (dual-chain)              │   │
│  │  ICP:  ICRC-2 transfer_from                    │   │
│  │  EVM:  EVM RPC canister → getTransactionReceipt│   │
│  └────────────────────────────────────────────────┘   │
│                                                       │
│  ┌ ─ ─ ─ ─ ─ ─ ─ ─ ─ ┐  ┌ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─┐   │
│  │ ContentStore (opt) │  │ Identity (opt)       │   │
│  │ Encrypted storage  │  │ ERC-8004 on Base     │   │
│  └ ─ ─ ─ ─ ─ ─ ─ ─ ─ ┘  └ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─┘   │
└──────────────────────────────────────────────────────┘
```

<details>
<summary>Payment flows</summary>

**x402 charge over HTTP:**
```
Client                    Canister                     EVM Chain
  │── GET /content/x ──────>│                               │
  │<── HTTP 402 ────────────│  (ICP + EVM payment options)  │
  │── send USDC ───────────────────────────────────────────>│
  │── GET + X-PAYMENT ─────>│── EVM RPC canister ──────────>│
  │<── HTTP 200 + content ──│<── getTransactionReceipt ─────│
```

**Session (streaming micropayments):** deposit via EIP-3009 (EVM) or ICRC-2 (ICP) → sign Ed25519 vouchers off-chain × N → close (canister settles consumed + refunds remainder via tECDSA). 2 on-chain txns for any number of calls.

</details>

## Demo

```bash
git clone https://github.com/vhew/ic402.git && cd ic402
pnpm setup:local    # installs deps, starts replica, deploys, funds accounts
pnpm demo     # interactive walkthrough
```

<details>
<summary>Prerequisites & demo details</summary>

**Prerequisites:** [ICP SDK](https://internetcomputer.org/docs/building-apps/getting-started/install) (`icp` CLI), [mops](https://mops.one), [Node.js](https://nodejs.org/) >= 22, [pnpm](https://pnpm.io/) >= 9.

**What `pnpm setup:local` does:** installs Motoko + Node deps, starts local replica, deploys ckUSDC ledger + EVM RPC canister + example canister, creates test identities, funds test accounts, builds TypeScript packages.

**Demo steps:**
1. Configure — connect, derive tECDSA EVM address
2. Upload Content — encrypted at rest
3. x402 over HTTP — hit paywall, pay with ICP or EVM, receive content
4. x402 Client — canister pays an external x402 API (GoldRush)
5. Sessions — streaming micropayments
6. Identity — ERC-8004 registration on Base
7. Policy — spending limits

**Optional: MetaMask cross-chain payment** — step 3 supports live USDC payment from MetaMask on Base Sepolia.

**Optional: EVM agent registration** — register on Base via `icp canister call example registerAgent '()' -e local` (requires ETH at the canister's EVM address).

</details>

## API Reference

### Gateway

| Method | Description |
|--------|-------------|
| `requireAll(amount)` | Generate ICP + all EVM payment requirements |
| `require(price)` | Generate a single PaymentRequirement (5-min nonce) |
| `requireEvm(amount)` | Generate EVM-only requirements |
| `settle(signature)` | Settle via ICRC-2 (ICP) or HTTPS outcall (EVM) |
| `offerSession(intent)` | Create a SessionIntent for negotiation |
| `openSession(...)` | Deposit escrow, create session |
| `consumeVoucher(voucher)` | Verify + consume a session voucher |
| `closeSession(caller, id)` | Settle consumed, refund remainder |
| `setPolicy(caller?, policy)` | Set global or per-caller spending policy |
| `issueGrant(...)` | Issue HMAC-verified access grant |
| `verifyGrant(grant)` | Verify grant authenticity + expiry |
| `startTimers<system>()` | Start session expiry + EVM address derivation |
| `toStable()` / `loadStable(data)` | Serialize/restore across upgrades |

### ContentStore (optional)

| Method | Description |
|--------|-------------|
| `put(id, mimeType, data)` | Encrypt + store (auto-chunks at 1.5 MB) |
| `get(id)` | Decrypt + retrieve |
| `list()` | All content metadata |
| `toStable()` / `loadStable(data)` | Serialize/restore |

### X402Client (optional)

| Method | Description |
|--------|-------------|
| `fetchWithPayment(url, method, body, headers, cache)` | Fetch x402 endpoint, pay if 402 |
| `fetch(url, method, body, headers)` | Same, without cached payment info |

Returns `#ok`, `#free`, `#paymentFailed`, `#httpError`, or `#transientError`.

### HttpHandler

| Method | Description |
|--------|-------------|
| `http402(requirements)` | Build HTTP 402 response with x402 JSON |
| `http200(body, mimeType)` / `http200Json(json)` | Build HTTP 200 |
| `httpUpgrade()` | Signal upgrade to update call |
| `parseX402PaymentHeader(base64)` | Parse x402 v2 header |
| `parsePaymentHeader(json)` | Parse legacy ic402 header |
| `getHeader(headers, name)` | Case-insensitive header lookup |
| `getPath(url)` / `getQueryParam(url, key)` | URL parsing |

### Identity (optional)

| Method | Description |
|--------|-------------|
| `getCard()` | Agent card metadata |
| `getPublicKey(keyName)` | Canister's secp256k1 key via tECDSA |
| `getEvmAddress()` | Derived EVM address |
| `registerAgent()` | Register on Base IdentityRegistry |

## Project structure

```
src/ic402/               Motoko library (published to mops)
  Gateway.mo             Charges, settlement, sessions, policy
  X402Client.mo          Canister-as-payer (EIP-3009 via tECDSA)
  HttpHandler.mo         x402 HTTP response helpers
  ContentStore.mo        Encrypted blob storage (optional)
  Identity.mo            ERC-8004 agent discovery (optional)
  Eip712.mo              EIP-712 typed data hashing
  EvmVerify.mo           Cross-chain tx verification
  EvmSender.mo           EVM transaction signing
  EvmUtils.mo            RLP, ABI encoding, hex conversion
  Types.mo               Shared types
example/                 Example canister + interactive demo
  main.mo                Reference implementation (all features)
  client/                Interactive demo client (drives the example)
packages/client/         TypeScript SDK (@ic402/client)
integrations/mcp/        MCP server (@ic402/mcp)
scripts/                 Dev tooling (setup, deployment, version bump)
```

## Development

```bash
pnpm install              # Node deps
mops test                 # Motoko unit tests
pnpm build:client         # TypeScript client SDK
pnpm demo                 # interactive demo (needs local replica)
pnpm setup:local                # deploy locally (full setup)
```

Source has **mainnet values**. Deploy scripts (`scripts/patch-local.sh`) patch chain IDs, USDC addresses, and tECDSA key names to testnet for local development. See [CONTRIBUTING.md](CONTRIBUTING.md) for details.

## Status

Production-ready. All core features implemented and tested.

**Limitations:**
- EVM verification uses the DFINITY EVM RPC canister (mainnet only — local replica uses a mock)
- x402 client settlement depends on the facilitator's reliability (~90% success rate on testnet)
- Auto-approval (ICRC-2) not yet in the TypeScript SDK

## License

[Apache 2.0](LICENSE)
