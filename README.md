# ic402

Everything a canister needs to get paid — x402 charges, streaming sessions, encrypted content, agent discovery.

## Why ICP

A canister holds state, runs compute, signs transactions, and serves HTTP — it *is* the server, the wallet, and the payment processor in one. ic402 adds the payment layer: charge per request, stream micropayments via sessions, deliver paid content, and settle cross-chain on Avalanche. One `import`, one deploy, no external infrastructure.

## What's different

| | x402-icp | Anda Facilitator | **ic402** |
|---|---|---|---|
| Charge (one-time) | Yes | Yes | **Yes** |
| Streaming sessions | No | No | **Yes — 5,000x cheaper** |
| Cross-chain (Avalanche) | No | No | **Yes — HTTPS outcall verification** |
| Policy engine | No | No | **Yes** |
| Agent discovery (ERC-8004) | No | No | **Yes — on Avalanche** |
| Drop-in library | No (Express middleware) | No (standalone canister) | **Yes — one import** |

### Why sessions matter

A pure x402 model requires one on-chain transaction per API call. On ICP, each ICRC-2 transfer costs ~$0.001 in cycles + fees. An agent making 10,000 calls/day pays ~$10 in settlement overhead alone. With sessions: deposit once, stream vouchers off-chain, settle on close. Those 10,000 calls settle in exactly 2 transactions (~$0.002). **5,000x reduction.**

### Why cross-chain matters

The canister derives a native Avalanche address via ICP's threshold ECDSA. When a client pays USDC on Avalanche, the canister verifies the transaction directly — HTTPS outcall to `eth_getTransactionReceipt`. No bridge. No oracle. The canister calls Avalanche's RPC endpoint and reads the receipt.

## How it works

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

**x402 charge (ICP):** request → 402 + requirement → ICRC-2 approve → retry with signature → settle → receipt

**x402 charge (Avalanche cross-chain):**

```
Client                   Canister                    Avalanche C-Chain
  │── request ──────────>│                               │
  │<── 402 + requirement │                               │
  │── send USDC ─────────────────────────────────────────>│
  │── retry + tx hash ──>│── HTTPS outcall ──────────────>│
  │                      │<── eth_getTransactionReceipt ──│
  │<── receipt ──────────│   (verify status + contract)   │
```

**Session (streaming micropayments):** deposit escrow → sign vouchers off-chain (free) × N → close (settle consumed, refund remainder). 2 on-chain transactions for any number of calls.

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
      avalanche = ?{  // optional: accept USDC on Avalanche too
        chainId = 43113;
        recipient = "0xYOUR_AVAX_ADDRESS";
        tokens = [{ address = "0x5425890298aed601595a70AB815c96711a31Bc65"; symbol = "USDC"; decimals = 6 : Nat8 }];
      };
    },
    Principal.fromActor(MyService),
  );

  // gate.require(price) → PaymentRequirement (402)
  // gate.settle(sig) → settles via ICRC-2 (ICP) or HTTPS outcall (Avalanche)
};
```

See `src/example/main.mo` for a full working example with paid services, sessions, three content delivery patterns, and ERC-8004 identity.

## Content delivery

Three patterns — pick the one that fits:

| Pattern | Where content lives | Delivery |
|---------|-------------------|----------|
| **In-canister** | Canister memory, encrypted (SHA-256-CTR) | Inline bytes or chunked query |
| **Asset canister** | Separate ICP canister | HTTP gateway URL |
| **External** | S3 / IPFS / Arweave | Pre-signed URL or decryption key |

All three are gated by the same payment flow. On payment, the canister issues an HMAC-verified AccessGrant with a TTL.

## Identity (ERC-8004)

The canister derives a native Avalanche address via tECDSA and registers as a discoverable agent on the IdentityRegistry contract. Other agents find it by querying the contract for skills, domains, or x402 support.

```motoko
transient let id = Ic402.Identity({
  chain = #avalanche;
  card = { name = "KnowledgeBase"; description = "..."; services = [...]; x402Support = true };
});

let pubkey = await id.getPublicKey("dfx_test_key"); // canister's secp256k1 key
```

Register on Avalanche Fuji:
```bash
pnpm register-agent --private-key 0xYOUR_AVAX_KEY
```

## Interactive demo

```bash
pnpm build:mcp-client
./deploy/deploy.sh        # or ./scripts/local-start.sh
pnpm demo
```

8 interactive steps through every use case — charges, cross-chain settlement, sessions, content delivery, identity, policy. Each step shows live infrastructure state (chain IDs, tECDSA addresses, contract addresses) and explains what's innovative.

## Policy engine

Dual-sided: the **client** enforces budget limits (max per request, daily cap) and the **canister** enforces server policy (rate limits, session caps, caller allowlists). Both sides enforce independently — safe for AI agents and service operators.

```motoko
gate.setPolicy(null, {
  maxPerTransaction = ?50_000;    // $0.05
  maxPerDay = ?500_000;           // $0.50
  rateLimitPerMinute = ?120;
  maxSessionDeposit = ?100_000;   // $0.10
  maxConcurrentSessions = ?1;
  maxSessionDuration = ?86_400_000_000_000; // 24h
  sessionIdleTimeout = ?3_600_000_000_000;  // 1h — auto-close + refund
  allowedCallers = null;
  blockedCallers = null;
});
```

## Project structure

```
src/ic402/               Motoko library (published to mops)
  Gateway.mo             Charge, session, policy, access grants
  EvmVerify.mo           Cross-chain Avalanche tx verification (HTTPS outcalls)
  ContentStore.mo        Encrypted blob storage (optional)
  Identity.mo            ERC-8004 agent cards + tECDSA (optional)
  Policy.mo              Spending limits engine
src/example/             Example canister (all features)
packages/client/         TypeScript SDK (@ic402/client)
integration/mcp/         MCP server (@ic402/mcp)
integration/mcp-client/  Interactive demo client
contracts/               Solidity — IdentityRegistry (Avalanche Fuji)
scripts/                 Version bump, .did generation, agent registration
deploy/                  Local + production deployment
```

## API reference

<details>
<summary>Gateway</summary>

| Method | Description |
|--------|-------------|
| `require(price)` | Generate a PaymentRequirement with 5-min nonce |
| `settle(signature)` | Settle via ICRC-2 (ICP) or HTTPS outcall (Avalanche) |
| `offerSession(intent)` | Return a SessionIntent for negotiation |
| `openSession(...)` | Deposit escrow, create session |
| `consumeVoucher(voucher)` | Verify + consume a session voucher |
| `closeSession(sessionId)` | Settle consumed, refund remainder |
| `setPolicy(caller?, policy)` | Set global or per-caller policy |
| `issueGrant(...)` | Issue HMAC-verified access grant |
| `verifyGrant(grant)` | Verify grant authenticity + expiry |

</details>

<details>
<summary>ContentStore (optional)</summary>

| Method | Description |
|--------|-------------|
| `put(id, mimeType, data)` | Encrypt + store, auto-chunk at 1.5 MB |
| `get(id)` | Decrypt + retrieve |
| `list()` | All content metadata |
| `toContentRef(id)` | Bridge to Gateway.issueGrant() |

</details>

<details>
<summary>Identity (optional)</summary>

| Method | Description |
|--------|-------------|
| `getCard()` | Agent card metadata |
| `getPublicKey(keyName)` | Canister's secp256k1 key via tECDSA |
| `getAgentId()` | Registered token ID on Avalanche |
| `setAgentId(id)` | Store ID after external registration |

</details>

<details>
<summary>Client SDK</summary>

| Method | Description |
|--------|-------------|
| `call(canisterId, method, args, actorFactory)` | Auto-handle 402 payment |
| `openSession(...)` | Open streaming session |
| `SessionHandle.call(method, args)` | Call with auto-signed voucher |
| `SessionHandle.close()` | Settle + refund |
| `fetchContent(delivery)` | Fetch from any delivery method |

</details>

## Status

Core payment flows, cross-chain settlement, and content delivery are functional.

**Working:** x402 charges (dual-chain), streaming sessions (5,000x reduction), encrypted content store, cross-chain agent discovery (ERC-8004 + tECDSA), policy engine, MCP server + interactive demo.

**Limitations:** Voucher signature verification is stubbed (Ed25519). Avalanche tx verification checks receipt status but does not yet decode ERC-20 Transfer event logs. On-canister EVM tx signing (Keccak + RLP in Motoko) is a future milestone.

See [docs/SPEC.md](docs/SPEC.md) for the full specification.

## License

[Apache 2.0](LICENSE)
