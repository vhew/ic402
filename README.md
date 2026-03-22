# ic402

Everything a canister needs to get paid — x402 charges, streaming sessions, encrypted content, agent discovery.

## Why ICP for x402

Normal x402 runs on a centralized HTTP server (Express, Cloudflare Worker) with an external facilitator (Coinbase) and a separate wallet. Three moving parts, all off-chain.

An ICP canister replaces all three. It serves HTTP natively, settles payments on-chain, and signs EVM transactions via threshold ECDSA — no external infrastructure. ic402 makes this a one-line import:

```motoko
import Ic402 "mo:ic402";
let gate = Ic402.Gateway({ /* config */ }, Principal.fromActor(self));
// gate.require(price) → HTTP 402 with PaymentRequirement
// gate.settle(sig)    → settles via ICRC-2 (ICP) or HTTPS outcall (Avalanche)
```

**Why ICP is uniquely suited:**
- **HTTPS outcalls** — the canister calls Avalanche's RPC directly to verify cross-chain payments. No oracle, no bridge.
- **tECDSA** — the canister derives a native Avalanche address. No external wallet, no key management.
- **HTTP serving** — the canister IS the HTTP server. Standard x402 402 responses, directly from the canister.
- **Stable memory** — encrypted content survives canister upgrades.

## What's different

| | x402-icp | Anda Facilitator | **ic402** |
|---|---|---|---|
| Charge (one-time) | Yes | Yes | **Yes** |
| HTTP 402 serving | External server | External server | **Canister serves HTTP natively** |
| Streaming sessions | No | No | **Yes — 5,000x cheaper** |
| Cross-chain (Avalanche) | No | No | **Yes — HTTPS outcall verification** |
| Encrypted content store | No | No | **Yes** |
| Policy engine | No | No | **Yes — dual-sided** |
| Agent discovery (ERC-8004) | No | No | **Yes — on Avalanche** |
| Drop-in library | No (Express middleware) | No (standalone canister) | **Yes — one import** |

### Sessions: 5,000x cheaper

A pure x402 model requires one on-chain transaction per API call. On ICP, each ICRC-2 transfer costs ~$0.001. An agent making 10,000 calls/day pays ~$10 in settlement overhead. With sessions: deposit once, stream vouchers off-chain, settle on close. 10,000 calls = 2 transactions = $0.002. **5,000x reduction.**

### Cross-chain: no bridge, no oracle

The canister derives a native Avalanche address via tECDSA. When a client pays USDC on Avalanche, the canister verifies the transaction directly — HTTPS outcall to `eth_getTransactionReceipt`. The canister calls the RPC endpoint and reads the receipt. No intermediary.

## What a 402 looks like

```bash
curl https://<canister-id>.raw.icp0.io/search?q=avalanche
```

```json
{
  "x402Version": 1,
  "accepts": [
    {
      "scheme": "exact",
      "network": "icp:1",
      "token": "xevnm-gaaaa-aaaar-qafnq-cai",
      "maxAmountRequired": "1000",
      "payTo": "<canister-principal>"
    },
    {
      "scheme": "exact",
      "network": "eip155:43113",
      "token": "0x5425890298aed601595a70AB815c96711a31Bc65",
      "maxAmountRequired": "1000",
      "payTo": "0x<canister-tecdsa-address>"
    }
  ]
}
```

**Two payment options in one 402.** Client picks ICP or Avalanche. Same price, same API.

## Architecture

```
┌──────────────────────────────────────────────────────────┐
│                      Your Canister                       │
│                                                          │
│  import Ic402 "mo:ic402"                                 │
│                                                          │
│  ┌──────────┐  ┌──────────┐  ┌────────────────┐         │
│  │ Charge   │  │ Session  │  │ Policy Engine  │         │
│  │ (x402)   │  │ (Escrow +│  │ (limits, rates)│         │
│  │          │  │ Vouchers)│  │                │         │
│  └────┬─────┘  └────┬─────┘  └───────┬────────┘         │
│       │              │               │                   │
│  ┌────▼──────────────▼───────────────▼──────────────┐    │
│  │          Settlement (dual-chain)                 │    │
│  │  ICP:  ICRC-2 transfer_from                      │    │
│  │  AVAX: HTTPS outcall → eth_getTransactionReceipt │    │
│  └──────────────────────────────────────────────────┘    │
│                                                          │
│  ┌ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─┐  ┌ ─ ─ ─ ─ ─ ─ ─ ─ ─ ┐    │
│  │ ContentStore (opt.)   │  │ Identity (opt.)     │    │
│  │ Encrypted blob storage│  │ ERC-8004 on         │    │
│  └ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─┘  │ Avalanche (tECDSA)  │    │
│                              └ ─ ─ ─ ─ ─ ─ ─ ─ ─ ┘    │
└──────────────────────────────────────────────────────────┘
```

### Payment flows

**x402 charge over HTTP:**

```
Client                   Canister                    Avalanche C-Chain
  │── GET /content/x ──>│                               │
  │<── HTTP 402 ────────│  (dual-chain payment options)  │
  │── send USDC ─────────────────────────────────────────>│
  │── GET + X-PAYMENT ─>│── HTTPS outcall ──────────────>│
  │                      │<── eth_getTransactionReceipt ──│
  │<── HTTP 200 + content│   (verify status + contract)   │
```

**Session (streaming micropayments):** deposit escrow → sign vouchers off-chain (free) × N → close (settle consumed, refund remainder). 2 on-chain txns for any number of calls.

## Interactive demo

The demo walks through the full flow — upload content, hit the paywall, pay from MetaMask on Avalanche, receive the content. Live cross-chain settlement in the terminal.

### Prerequisites

- [ICP SDK](https://internetcomputer.org/docs/building-apps/getting-started/install) (`icp` CLI)
- [mops](https://mops.one) (Motoko package manager)
- [Node.js](https://nodejs.org/) >= 22
- [pnpm](https://pnpm.io/) >= 9

### Run

```bash
git clone https://github.com/vhew/ic402.git && cd ic402
pnpm setup    # installs deps, starts replica, deploys canisters, funds accounts
pnpm demo     # interactive 6-step walkthrough
```

`pnpm setup` handles everything: `mops install`, `pnpm install`, local replica, ckUSDC ledger, example canister (patched for local ledger + tECDSA AVAX address), test identities, ckUSDC funding, ICRC-2 approval, and TypeScript build.

### Optional: MetaMask cross-chain payment

Step 3 of the demo offers a live cross-chain payment from MetaMask. To try it:
1. Get testnet USDC from the [Circle faucet](https://faucet.circle.com/) (select Avalanche Fuji)
2. The demo shows the recipient address and amount
3. Send USDC from MetaMask, paste the tx hash
4. The canister verifies the tx via HTTPS outcall to Avalanche RPC

### Optional: Avalanche agent registration

Register the canister as an ERC-8004 agent on Avalanche Fuji:
```bash
brew install foundry                                        # one-time
pnpm register-agent --private-key 0xYOUR_FUJI_PRIVATE_KEY   # deploy contract + register
```
Get testnet AVAX from [faucet.avax.network](https://faucet.avax.network).

### What to expect

The demo is a CLI application — 6 interactive steps, each with Enter/skip/quit controls. It connects to the canister via MCP, makes live HTTP requests, and shows infrastructure state at each step. The output is colored with status indicators and innovation callouts.

6 steps:

1. **Configure** — connect to canister, derive tECDSA Avalanche address
2. **Upload Content** — upload via MCP, content encrypted at rest (SHA-256-CTR)
3. **x402 over HTTP** — hit the paywall, see dual-chain options, optionally **pay from MetaMask on Fuji** and watch the canister verify the tx via HTTPS outcall
4. **Sessions** — streaming micropayments, 5,000x cheaper than per-call
5. **Agent Discovery** — ERC-8004 registration on Avalanche ([verify on Snowtrace](https://testnet.snowtrace.io))
6. **Policy** — dual-sided spending limits, full infrastructure summary

## Avalanche integration

| Component | Address / ID | Verify |
|-----------|-------------|--------|
| IdentityRegistry contract | `0x0F3998E6E4287fa7a5620979c5513D8e83fE80D3` | [Snowtrace](https://testnet.snowtrace.io/address/0x0F3998E6E4287fa7a5620979c5513D8e83fE80D3) |
| Canister AVAX address | Derived via tECDSA at runtime | Shown in demo step 1 |
| USDC (Fuji testnet) | `0x5425890298aed601595a70AB815c96711a31Bc65` | [Token on Snowtrace](https://testnet.snowtrace.io/address/0x5425890298aed601595a70AB815c96711a31Bc65) |

Register the canister as an ERC-8004 agent on Avalanche:
```bash
pnpm register-agent --private-key 0xYOUR_FUJI_KEY
```

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
      tokens = [{ ledger = Principal.fromText("xevnm-gaaaa-aaaar-qafnq-cai"); symbol = "ckUSDC"; decimals = 6 }];
      avalanche = ?{
        chainId = 43113;
        recipient = "0xYOUR_AVAX_ADDRESS";
        tokens = [{ address = "0x5425890298aed601595a70AB815c96711a31Bc65"; symbol = "USDC"; decimals = 6 : Nat8 }];
      };
    },
    Principal.fromActor(MyService),
  );

  // HTTP x402 endpoint
  public query func http_request(request : Ic402.HttpRequest) : async Ic402.HttpResponse {
    // Returns HTTP 402 with payment options for paid endpoints
    // Returns HTTP 200 for free endpoints
  };

  public shared func http_request_update(request : Ic402.HttpRequest) : async Ic402.HttpResponse {
    // Settles payment (ICRC-2 or Avalanche HTTPS outcall) and returns content
  };
};
```

See `src/example/main.mo` for the full working example.

## Content delivery

Content is **encrypted at rest** (SHA-256-CTR) — even node operators can't read it. Payment unlocks an HMAC-signed AccessGrant with a TTL. Three delivery backends:

| Pattern | Storage | Delivery |
|---------|---------|----------|
| **In-canister** | Canister stable memory | Inline bytes or chunked query |
| **Asset canister** | Separate ICP canister | HTTP gateway URL |
| **External** | S3 / IPFS / Arweave | Pre-signed URL (tECDSA) or decryption key |

## Policy engine

Dual-sided — the **client** enforces budget limits (can never be drained) and the **canister** enforces server policy (can never be abused). No other x402 implementation has this.

```motoko
gate.setPolicy(null, {
  maxPerTransaction = ?50_000;    // $0.05
  maxPerDay = ?500_000;           // $0.50
  rateLimitPerMinute = ?120;
  maxSessionDeposit = ?100_000;   // $0.10
  maxConcurrentSessions = ?1;
  sessionIdleTimeout = ?3_600_000_000_000;  // 1h — auto-close + refund
});
```

## Project structure

```
src/ic402/               Motoko library (published to mops)
  Gateway.mo             Charge, session, policy, access grants, HTTP handler
  EvmVerify.mo           Cross-chain Avalanche tx verification (HTTPS outcalls)
  ContentStore.mo        Encrypted blob storage (optional)
  Identity.mo            ERC-8004 agent cards + tECDSA (optional)
  HttpHandler.mo         x402 HTTP response helpers
src/example/             Example canister (all features, serves HTTP)
packages/client/         TypeScript SDK (@ic402/client)
integration/mcp/         MCP server (@ic402/mcp)
integration/mcp-client/  Interactive demo client
contracts/               IdentityRegistry.sol (deployed to Avalanche Fuji)
scripts/                 Agent registration, version bump, .did generation
deploy/                  Local + production deployment
```

<details>
<summary>API reference</summary>

### Gateway

| Method | Description |
|--------|-------------|
| `require(price)` | Generate a PaymentRequirement (5-min nonce) |
| `requireAvax(amount)` | Generate an Avalanche PaymentRequirement |
| `settle(signature)` | Settle via ICRC-2 (ICP) or HTTPS outcall (Avalanche) |
| `offerSession(intent)` | Return a SessionIntent for negotiation |
| `openSession(...)` | Deposit escrow, create session |
| `consumeVoucher(voucher)` | Verify + consume a session voucher |
| `closeSession(sessionId)` | Settle consumed, refund remainder |
| `setPolicy(caller?, policy)` | Set global or per-caller policy |
| `issueGrant(...)` | Issue HMAC-verified access grant |
| `verifyGrant(grant)` | Verify grant authenticity + expiry |

### ContentStore (optional)

| Method | Description |
|--------|-------------|
| `put(id, mimeType, data)` | Encrypt + store, auto-chunk at 1.5 MB |
| `get(id)` | Decrypt + retrieve |
| `list()` | All content metadata |

### Identity (optional)

| Method | Description |
|--------|-------------|
| `getCard()` | Agent card metadata |
| `getPublicKey(keyName)` | Canister's secp256k1 key via tECDSA |
| `getAgentId()` | Registered token ID on Avalanche |

### HttpHandler

| Method | Description |
|--------|-------------|
| `http402(requirements)` | Build HTTP 402 response with x402 JSON |
| `http200(body, mimeType)` | Build HTTP 200 response |
| `httpUpgrade()` | Signal HTTP gateway to retry as update call |
| `parsePaymentHeader(json)` | Parse X-PAYMENT header into PaymentSignature |

</details>

## Status

Core payment flows, cross-chain settlement, HTTP serving, and content delivery are functional.

**Working:** HTTP x402 (standard 402 responses from canister), dual-chain settlement (ICP ICRC-2 + Avalanche USDC via HTTPS outcall), streaming sessions (5,000x reduction), encrypted content store, cross-chain agent discovery (ERC-8004 + tECDSA on Avalanche Fuji), policy engine, MCP server + interactive demo with live MetaMask payment.

**Limitations:** Voucher Ed25519 signature verification is stubbed. Avalanche tx verification checks receipt status but does not yet decode ERC-20 Transfer event logs. On-canister EVM tx signing (Keccak + RLP in Motoko) is a future milestone.

See [docs/SPEC.md](docs/SPEC.md) for the full specification.

## License

[Apache 2.0](LICENSE)
