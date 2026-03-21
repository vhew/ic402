# agentflow — Specification

> Drop-in payment library for ICP canisters. x402 charges, streaming sessions, ERC-8004 agent identity.

**Version:** 1.0.0-draft
**Date:** 2026-03-20
**Status:** Hackathon MVP

---

## Table of Contents

1. [Overview](#1-overview)
2. [Why ICP](#2-why-icp)
3. [Architecture](#3-architecture)
4. [Payment Models](#4-payment-models)
5. [Policy Engine](#5-policy-engine)
6. [ERC-8004 Agent Identity](#6-erc-8004-agent-identity)
7. [Library API](#7-library-api)
8. [TypeScript Client SDK](#8-typescript-client-sdk)
9. [Example Canister](#9-example-canister)
10. [Security](#10-security)
11. [Testing](#11-testing)
12. [Future Work](#12-future-work)

---

## 1. Overview

agentflow is a Motoko library that any ICP canister can import to accept and send payments via x402, with a streaming session model for micropayments, and ERC-8004 agent identity on Avalanche.

**What it does:**

```motoko
import Agentflow "mo:agentflow";

let gate = Agentflow.Gateway({ /* config */ });

// One-time payment (x402 charge)
switch (await gate.settle(sig)) { case (#ok(receipt)) { /* serve resource */ } };

// Streaming session (escrow + vouchers)
let session = await gate.openSession(caller, intent, config, sig);
switch (gate.consumeVoucher(voucher)) { case (#ok(delta)) { /* serve resource */ } };
await gate.closeSession(sessionId);  // settles on-chain, refunds remainder
```

**What makes it different from existing x402-icp implementations:**

| Feature                                 | x402-icp              | Anda Facilitator       | agentflow |
|-----------------------------------------|-----------------------|------------------------|-----------|
| Charge (one-time)                       | Yes                   | Yes                    | Yes       |
| Session (streaming micropayments)       | No                    | No                     | **Yes**   |
| Policy engine (daily caps, rate limits) | No                    | No                     | **Yes**   |
| ERC-8004 agent identity                 | No                    | No                     | **Yes**   |
| Drop-in canister library                | No (Express middleware)| No (standalone canister)| **Yes**   |

---

## 2. Why ICP

AI agents need to pay for services autonomously. They need somewhere to run, hold keys, enforce budgets, and settle payments. ICP is the right execution layer because:

**Canister = autonomous agent.** A canister is a full program that runs on-chain: HTTP outcalls, timers, 400GB stable memory, arbitrary compute. It doesn't need an external server, RPC provider, or relayer.

**Threshold keys, not hot wallets.** tECDSA/tSchnorr: the canister holds signing keys distributed across subnet nodes. No private key to leak. The canister signs Avalanche (EVM) transactions natively.

**Reverse gas makes micropayments viable.** On ICP, the canister pays for compute (cycles), not the caller. An ICRC-2 transfer costs ~$0.0001 in cycles. On Avalanche C-Chain, an equivalent approve+transfer costs ~$0.01-0.05. For an agent making 1,000 micropayments/day, that's $0.10 vs $10-50.

**Honest trade-offs:**

| Metric                     | ICP                       | Avalanche C-Chain          |
|----------------------------|---------------------------|----------------------------|
| Per-payment cost           | ~$0.0001                  | ~$0.01-0.05                |
| Consensus latency          | ~2s                       | ~1s                        |
| tECDSA cross-chain signing | ~$0.03, ~12s              | N/A (native)               |
| Developer ecosystem        | Smaller                   | Larger (EVM)               |
| Agent compute              | Full programs (canisters) | Limited (smart contracts)  |

The latency and tECDSA cost matter. That's why the session model is critical: deposit once (1 tECDSA sig for cross-chain, or 1 ICRC-2 transfer for ICP-native), then sign thousands of vouchers in-canister with zero additional on-chain cost.

---

## 3. Architecture

```
┌──────────────────────────────────────────────────────────┐
│                    Your Canister                         │
│                                                          │
│   import Agentflow "mo:agentflow"                        │
│                                                          │
│   ┌────────────┐  ┌────────────┐  ┌──────────────────┐   │
│   │  Charge    │  │  Session   │  │  Policy Engine   │   │
│   │  (x402)    │  │  (Escrow + │  │  (limits, rates, │   │
│   │            │  │  Vouchers) │  │   daily caps)    │   │
│   └─────┬──────┘  └─────┬──────┘  └────────┬─────────┘   │
│         │               │                  │             │
│   ┌─────▼───────────────▼──────────────────▼──────────┐  │
│   │              ICRC-2 Settlement                    │  │
│   └───────────────────────────────────────────────────┘  │
│         │                                    │           │
│   ┌─────▼──────┐                    ┌────────▼────────┐  │
│   │  ERC-8004  │                    │  tECDSA Signer  │  │
│   │  Identity  │                    │  (Avalanche)    │  │
│   └────────────┘                    └─────────────────┘  │
└──────────────────────────────────────────────────────────┘
```

Three core components, all in the same canister:

1. **Charge** — x402 "exact" scheme. One ICRC-2 transfer per request.
2. **Session** — ICRC-2 escrow deposit + cumulative vouchers. One settlement on close.
3. **Policy Engine** — Per-caller limits, daily caps, rate limits. Runs in-canister for free.

Plus two optional integrations:

4. **ERC-8004** — Register as a discoverable agent on Avalanche (via tECDSA).
5. **tECDSA** — Accept payments on Avalanche C-Chain.

---

## 4. Payment Models

### 4.1 Charge (x402 "exact")

One-time atomic payment per request. Matches the existing x402 protocol exactly.

```
Client                   Canister (agentflow)             ICRC-2 Ledger
  │                            │                               │
  │── request ────────────────>│                               │
  │<── 402 + PaymentRequired ──│                               │
  │                            │                               │
  │── icrc2_approve ──────────────────────────────────────────>│
  │<── confirmed ──────────────────────────────────────────────│
  │                            │                               │
  │── request + PaymentSig ───>│                               │
  │                            │── verify sig                  │
  │                            │── policy check                │
  │                            │── icrc2_transfer_from ───────>│
  │                            │<── confirmed ─────────────────│
  │<── 200 + receipt ──────────│                               │
```

**When to use:** Infrequent calls, amounts > $0.01, simple integration.

### 4.2 Session (Escrow + Cumulative Vouchers)

Streaming payments via ICRC-2 escrow and cumulative vouchers. Client deposits funds once, then signs lightweight vouchers per call. No on-chain transaction until session close. This is agentflow's core innovation — it solves the micropayment problem that makes per-request x402 charges uneconomical for high-frequency agent interactions.

**Why sessions matter:** A pure x402 charge model requires one on-chain transaction per API call. Even on ICP (~$0.0001/tx), an agent making 10,000 calls/day would pay $1 in settlement overhead alone. With sessions, those 10,000 calls settle in exactly 2 transactions (deposit + close), costing ~$0.0002 total — a 5,000x reduction.

**Why ICP is uniquely suited for sessions:**

- **Canister-as-escrow.** The escrow is a subaccount of the canister itself — no external smart contract, no bridge, no intermediary. The canister holds the funds, verifies vouchers, and settles atomically. On EVM chains, this requires deploying a separate escrow contract and paying gas for every interaction with it.
- **Reverse gas model.** The payer never pays gas. The canister pays cycles for computation, and ICRC-2 transfer fees are fixed (~0.0001 ckUSDC). On Avalanche C-Chain, the payer pays gas for the deposit approval (~$0.02) and the server pays gas for settlement (~$0.02). These fees can exceed the value of micropayments.
- **Threshold signatures for cross-chain.** If a session needs to settle on Avalanche, the canister signs the EVM transaction via tECDSA — once, on close. No hot wallet, no relayer, no bridge. The session absorbs the ~$0.03 tECDSA cost across thousands of calls instead of paying it per-call.
- **Stable memory survives upgrades.** Session state (deposits, voucher counters, escrow subaccount balances) persists across canister upgrades. On-ledger ICRC-2 balances are independent of canister state entirely — even if the canister crashes, the escrowed funds are safe on the ledger.

```
Client                   Canister (agentflow)             ICRC-2 Ledger
  │                            │                               │
  │── requestAccess ──────────>│                               │
  │<── 402 + SessionOffer ─────│                               │
  │   {suggestedDeposit: 1,    │                               │
  │    costPerCall: 0.001}     │                               │
  │                            │                               │
  │── openSession ────────────>│                               │
  │   {maxDeposit: 0.5}        │                               │
  │                            │── icrc2_transfer_from ───────>│
  │                            │   (0.5 ckUSDC to escrow)      │
  │                            │<── confirmed ─────────────────│
  │<── SessionState ───────────│                               │
  │   {deposited: 0.5,         │                               │
  │    sessionId: "s-001"}     │                               │
  │                            │                               │
  │── call + voucher #1 ──────>│                               │
  │   {cumulative: 0.001}      │── verify sig (no tx) ──>     │
  │<── response ───────────────│                               │
  │                            │                               │
  │── call + voucher #2 ──────>│                               │
  │   {cumulative: 0.002}      │── verify sig (no tx) ──>     │
  │<── response ───────────────│                               │
  │                            │                               │
  │   ... (N calls, 0 txs) ... │                               │
  │                            │                               │
  │── closeSession ───────────>│                               │
  │                            │── transfer consumed ─────────>│
  │                            │   (0.002 to recipient)        │
  │                            │── refund remainder ──────────>│
  │                            │   (0.498 to client)           │
  │<── receipt ────────────────│                               │
```

**When to use:** High-frequency calls (>10/session), amounts < $0.01 per call, AI agents consuming APIs.

### 4.3 Deposit Negotiation

The server suggests a budget; the client caps it. The actual deposit is `min(suggestedDeposit, maxDeposit)`. If the result is below `minDeposit`, the session is rejected.

| Parameter          | Set By | Purpose                                                      |
|--------------------|--------|--------------------------------------------------------------|
| `suggestedDeposit` | Server | "I recommend depositing this much for typical usage"         |
| `minDeposit`       | Server | "I won't open a session for less than this"                  |
| `maxDeposit`       | Client | "I will never lock more than this" (client's cap always wins)|
| `costPerCall`      | Server | Hint for client budgeting (not enforced)                     |

### 4.4 Voucher Mechanics

Each voucher states the *cumulative* amount consumed, not the delta. Vouchers are signed by the payer and verified by the canister.

```
Voucher {
  sessionId : Text,
  cumulativeAmount : Nat,   // Total consumed so far (monotonically increasing)
  sequence : Nat,           // Monotonic counter (prevents replay)
  signature : Blob,         // Ed25519 sign(payer_key, cbor(sessionId, cumulativeAmount, sequence))
}
```

Verification rules:
- Signature must match the payer principal that opened the session
- `sequence` must be strictly greater than the last accepted sequence
- `cumulativeAmount` must be >= previous and <= deposited amount
- `cumulativeAmount - lastCumulativeAmount` = delta (amount consumed by this voucher)

**Latency consideration:** Voucher verification in the canister is an **update call** (~2s consensus). For most AI agent use cases (API calls that themselves take 100ms-10s), 2s overhead is acceptable. For latency-critical use cases, a future optimization could use **query calls** for stateless verification with batched state updates via timer — noted in [Future Work](#12-future-work).

### 4.5 Escrow Subaccounts

Session deposits are held in deterministic subaccounts of the canister:

```
escrow_subaccount = sha256("agentflow-escrow" ++ sessionId)
```

This isolates funds per session. On close, the canister transfers consumed amount to the recipient and refunds the remainder to the payer. If the canister crashes or upgrades mid-session, the subaccount balance is intact in stable memory and can be settled on recovery.

---

## 5. Policy Engine

The policy engine enforces spending limits that x402 leaves to the application layer. Policies are stored in stable memory and apply across both charges and sessions.

### 5.1 Policy Fields

```motoko
public type SpendingPolicy = {
  // Charge limits
  maxPerTransaction : ?Nat;     // Max per single charge (default: unlimited)
  maxPerDay : ?Nat;             // Rolling 24h cap, charges + sessions (default: unlimited)
  rateLimitPerMinute : ?Nat;    // Max charges or vouchers per minute (default: 60)

  // Session limits
  maxSessionDeposit : ?Nat;     // Max escrow per session (default: unlimited)
  maxConcurrentSessions : ?Nat; // Max open sessions per caller (default: 1)
  maxSessionDuration : ?Int;    // Max session lifetime, nanoseconds (default: 24h)
  sessionIdleTimeout : ?Int;    // Auto-close after inactivity (default: 1h)

  // Access control
  allowedCallers : ?[Principal]; // Whitelist (default: all)
  blockedCallers : ?[Principal]; // Blacklist (default: none)
};
```

### 5.2 Evaluation

**For charges:**

1. Blocked? → reject
2. Allowed? → reject if set and not in list
3. ERC-8004 reputation check (if configured) → reject if below threshold
4. Rate limit → reject if exceeded
5. `maxPerTransaction` → reject if amount exceeds
6. `maxPerDay` → reject if daily cumulative + amount exceeds
7. Settle

**For session open:**

1. Steps 1-3 same as charges
2. `maxConcurrentSessions` → reject if at limit
3. `maxSessionDeposit` → reject if deposit exceeds
4. `maxPerDay` → reject if daily cumulative + deposit exceeds
5. Open

**For vouchers:**

1. Rate limit → reject if exceeded
2. `maxPerDay` → reject if daily cumulative + delta exceeds
3. Verify signature, sequence, amount
4. Accept

### 5.3 Daily Aggregation

`maxPerDay` tracks a rolling 24-hour window across both charges and session consumption. If a caller spent 8 ckUSDC via charges and their `maxPerDay` is 10, they can only consume 2 more via sessions or charges.

### 5.4 Budget Alerts

```motoko
public type BudgetAlert = {
  #dailyThreshold : Nat;      // Alert when daily spend reaches this
  #sessionThreshold : Float;  // Alert at X% consumed (e.g., 0.8)
};

public func setAlert(alert : BudgetAlert, callback : shared () -> async ()) : ();
```

### 5.5 Admin

```motoko
public shared(msg) func setGlobalPolicy(policy : SpendingPolicy) : async ();
public shared(msg) func setCallerPolicy(caller : Principal, policy : SpendingPolicy) : async ();
public shared(msg) func removeCallerPolicy(caller : Principal) : async ();
public query func getGlobalPolicy() : async SpendingPolicy;
public shared(msg) func forceCloseSession(sessionId : Text) : async PaymentResult;
```

---

## 6. ERC-8004 Agent Identity

ERC-8004 ("Trustless Agents") defines on-chain registries for agent identity and reputation. agentflow registers canisters as agents on Avalanche (via tECDSA) so they can be discovered and trusted by other agents.

### 6.1 Registration

```motoko
let identity = gate.registerAgent();
// Signs an EVM tx via tECDSA → mints an ERC-721 on Avalanche IdentityRegistry
// Agent card (JSON) served from canister HTTP endpoint
```

The agent card follows ERC-8004 Registration v1:

```json
{
  "type": "https://eips.ethereum.org/EIPS/eip-8004#registration-v1",
  "name": "PriceFeedBot",
  "description": "Real-time crypto price data, pay-per-query via x402",
  "services": [{
    "name": "getPrice",
    "endpoint": "https://price-feed.icp0.io/api",
    "version": "1.0.0",
    "skills": ["price-feed"],
    "domains": ["defi"]
  }],
  "x402Support": true,
  "active": true
}
```

### 6.2 Reputation

After a payment, either party can post feedback to the ReputationRegistry:

```motoko
await gate.giveFeedback({
  agentId = providerAgentId;
  value = 95;
  tag1 = "successRate";
  proofOfPayment = receipt.txHash;
});
```

Proof-of-payment (x402 txHash) prevents sybil feedback — you can only review agents you actually paid.

### 6.3 Discovery

```motoko
let agents = await gate.discoverAgents({
  chain = #avalanche;
  skills = ["price-feed"];
  x402Support = true;
});
```

### 6.4 Trust-Gated Payments

Optional: reject payments from agents below a reputation threshold.

```motoko
let gate = Agentflow.Gateway({
  // ...
  trustRequirements = ?{ minReputation = 60; requiredTags = ["starred"] };
});
```

**Caveat:** ERC-8004 registries are new (January 2026). Most agents have no reputation yet. Trust gating is useful for the demo but aspirational for production until the ecosystem matures.

### 6.5 Registry Addresses

Deterministic on all EVM chains:

| Registry           | Address                                      |
|--------------------|----------------------------------------------|
| IdentityRegistry   | `0x8004A169FB4a3325136EB29fA0ceB6D2e539a432` |
| ReputationRegistry | `0x8004BAa17C55a88189AE136b182e5fdA19dE9b63` |

---

## 7. Library API

### 7.1 Configuration

```motoko
import Agentflow "mo:agentflow";

let gate = Agentflow.Gateway({
  recipient = { owner = Principal.fromActor(this); subaccount = null };

  tokens = [{
    ledger = Principal.fromText("xevnm-gaaaa-aaaar-qafnq-cai");
    symbol = "ckUSDC";
    decimals = 6;
  }];

  // Optional: ERC-8004 on Avalanche
  erc8004 = ?{
    chain = #avalanche;
    card = {
      name = "MyService";
      description = "Pay-per-query data API";
      services = [{ name = "query"; endpoint = "https://my-canister.icp0.io"; version = "1.0.0"; skills = ["data"]; domains = ["analytics"] }];
      x402Support = true;
    };
  };

  // Optional: accept payments on Avalanche
  avalanche = ?{
    chainId = 43114;
    recipient = "0x...";
    tokens = [{ address = "0xB97EF9Ef8734C71904D8002F8b6Bc66Dd9c48a6E"; symbol = "USDC"; decimals = 6 }];
  };
});
```

### 7.2 Types

```motoko
module Agentflow {

  // --- Charge ---

  public type PaymentRequirement = {
    scheme : Text;       // "exact"
    network : Text;      // CAIP-2: "icp:1" or "eip155:43114"
    token : Text;        // Ledger principal or EVM address
    amount : Nat;        // Smallest unit
    recipient : Text;
    nonce : Blob;
    expiry : Int;        // Nanoseconds since epoch
  };

  public type PaymentSignature = {
    scheme : Text;
    network : Text;
    signature : Blob;
    sender : Text;
    nonce : Blob;
  };

  public type PaymentReceipt = {
    id : Text;
    amount : Nat;
    token : Text;
    sender : Text;
    recipient : Text;
    network : Text;
    timestamp : Int;
    txHash : ?Text;
    sessionId : ?Text;
    refunded : ?Nat;     // Unspent session deposit returned
  };

  public type PaymentResult = {
    #ok : PaymentReceipt;
    #insufficientFunds;
    #invalidSignature;
    #expired;
    #policyDenied : Text;
    #tokenNotAccepted;
    #networkNotSupported;
    #settlementFailed : Text;
    #reputationTooLow : Nat;
    #depositBelowMinimum : Nat;
  };

  // --- Session ---

  public type SessionIntent = {
    network : Text;
    token : Text;
    recipient : Text;
    suggestedDeposit : Nat;
    minDeposit : ?Nat;
    expiry : Int;
    costPerCall : ?Nat;
    description : ?Text;
  };

  public type SessionConfig = {
    maxDeposit : Nat;
    autoClose : Bool;
    idleTimeout : ?Int;
  };

  public type SessionState = {
    id : Text;
    deposited : Nat;
    consumed : Nat;
    remaining : Nat;
    voucherCount : Nat;
    status : { #open; #closing; #closed; #expired };
    openedAt : Int;
    lastActivityAt : Int;
  };

  public type Voucher = {
    sessionId : Text;
    cumulativeAmount : Nat;
    sequence : Nat;
    signature : Blob;
  };

  public type VoucherResult = {
    #ok : Nat;              // delta
    #insufficientDeposit;
    #invalidSignature;
    #invalidSequence;
    #sessionNotOpen;
    #policyDenied : Text;
  };

  // --- Pricing ---

  public type Price = {
    token : Principal;
    amount : Nat;
    network : Text;
  };
}
```

### 7.3 Gateway Methods

```motoko
public class Gateway(config : Config) {

  // --- Charge ---
  public func require(price : Price) : PaymentRequirement;
  public func settle(signature : PaymentSignature) : async PaymentResult;

  // --- Session ---
  public func offerSession(intent : SessionIntent) : SessionIntent;
  public func openSession(caller : Principal, intent : SessionIntent, config : SessionConfig, sig : PaymentSignature) : async Result<SessionState, PaymentResult>;
  public func consumeVoucher(voucher : Voucher) : VoucherResult;
  public func getSession(sessionId : Text) : ?SessionState;
  public func closeSession(sessionId : Text) : async PaymentResult;
  public func closeExpiredSessions() : async [PaymentResult];

  // --- Policy ---
  public func setPolicy(caller : ?Principal, policy : SpendingPolicy) : ();
  public func getPolicy(caller : Principal) : SpendingPolicy;
  public func dailySpend(caller : Principal) : Nat;

  // --- ERC-8004 ---
  public func registerAgent() : async Nat;
  public func giveFeedback(feedback : ReputationFeedback) : async ();
  public func checkReputation(agentId : Nat, tag : Text) : async ReputationSummary;
  public func discoverAgents(query : DiscoverQuery) : async [AgentInfo];
}
```

---

## 8. TypeScript Client SDK

### 8.1 Install

```
npm install @agentflow/client
```

### 8.2 Charge (one-time)

```typescript
import { AgentflowClient } from "@agentflow/client";

const client = new AgentflowClient({
  identity: myIdentity,
  network: "icp:1",
  autoPayment: true,
  maxPerRequest: 100_000n,
});

// Auto-handles 402 → approve → retry
const data = await client.call(canisterId, "getPrice", ["BTC"]);
```

### 8.3 Session (streaming)

```typescript
const session = await client.openSession(canisterId, {
  maxDeposit: 500_000n,   // 0.50 ckUSDC
  autoClose: true,
  idleTimeout: 3600_000_000_000n,
});

// Each call auto-signs a cumulative voucher
const a1 = await session.call("query", ["What is x402?"]);
const a2 = await session.call("query", ["How do sessions work?"]);
// ... 1000 more calls, 0 on-chain txs ...

console.log(`${session.consumed} of ${session.deposited} consumed`);

const receipt = await session.close();
console.log(`Refunded: ${receipt.refunded}`);
```

### 8.4 Wrapped Fetch (HTTP endpoints)

```typescript
import { wrapFetch } from "@agentflow/client";

const paidFetch = wrapFetch(fetch, {
  identity: myIdentity,
  network: "icp:1",
  maxAmount: 100_000n,
});

const res = await paidFetch("https://my-canister.icp0.io/api/data");
```

### 8.5 Discovery

```typescript
const agents = await client.discoverAgents({
  chain: "eip155:43114",
  skills: ["price-feed"],
});

const best = agents.sort((a, b) => b.reputation - a.reputation)[0];
const data = await client.call(best.canisterId, "getPrice", ["BTC"]);
```

---

## 9. Example Canister

A paid knowledge base with both charge and session endpoints.

```motoko
import Agentflow "mo:agentflow";
import Principal "mo:base/Principal";
import Time "mo:base/Time";

actor KnowledgeBase {

  let gate = Agentflow.Gateway({
    recipient = { owner = Principal.fromActor(KnowledgeBase); subaccount = null };
    tokens = [{
      ledger = Principal.fromText("xevnm-gaaaa-aaaar-qafnq-cai");
      symbol = "ckUSDC";
      decimals = 6;
    }];
    erc8004 = ?{
      chain = #avalanche;
      card = {
        name = "KnowledgeBase";
        description = "AI-readable knowledge base, pay per query";
        services = [{
          name = "query";
          endpoint = "https://kb.icp0.io";
          version = "1.0.0";
          skills = ["knowledge-base", "search"];
          domains = ["ai", "data"];
        }];
        x402Support = true;
      };
    };
    avalanche = null;
  });

  // Policy: 10 ckUSDC/day, 1 session at a time, 1h idle timeout
  gate.setPolicy(null, {
    maxPerTransaction = ?1_000_000;
    maxPerDay = ?10_000_000;
    rateLimitPerMinute = ?120;
    maxSessionDeposit = ?5_000_000;
    maxConcurrentSessions = ?1;
    maxSessionDuration = ?(24 * 60 * 60 * 1_000_000_000);
    sessionIdleTimeout = ?(60 * 60 * 1_000_000_000);
    allowedCallers = null;
    blockedCallers = null;
  });

  // Register on ERC-8004 at first upgrade
  system func postupgrade() { ignore gate.registerAgent() };

  // ── Charge endpoint: 0.05 ckUSDC per call ──

  public shared(msg) func search(
    query : Text,
    paymentSig : ?Agentflow.PaymentSignature,
  ) : async {
    #paymentRequired : Agentflow.PaymentRequirement;
    #ok : [Text];
    #error : Text;
  } {
    let price = { token = Principal.fromText("xevnm-gaaaa-aaaar-qafnq-cai"); amount = 50_000; network = "icp:1" };

    switch (paymentSig) {
      case (null) { #paymentRequired(gate.require(price)) };
      case (?sig) {
        switch (await gate.settle(sig)) {
          case (#ok(_)) { #ok(doSearch(query)) };
          case (#policyDenied(r)) { #error("Policy: " # r) };
          case (_) { #paymentRequired(gate.require(price)) };
        };
      };
    };
  };

  // ── Session endpoint: open a streaming session ──

  public shared(msg) func requestSession() : async Agentflow.SessionIntent {
    gate.offerSession({
      network = "icp:1";
      token = Principal.toText(Principal.fromText("xevnm-gaaaa-aaaar-qafnq-cai"));
      recipient = Principal.toText(Principal.fromActor(KnowledgeBase));
      suggestedDeposit = 1_000_000;  // 1 ckUSDC
      minDeposit = ?100_000;         // min 0.1 ckUSDC
      expiry = Time.now() + 300_000_000_000;
      costPerCall = ?1_000;          // ~0.001 ckUSDC per query
      description = ?"Knowledge base session - pay per query";
    });
  };

  public shared(msg) func openSession(
    config : Agentflow.SessionConfig,
    sig : Agentflow.PaymentSignature,
  ) : async Result<Agentflow.SessionState, Text> {
    let intent = await requestSession();
    switch (await gate.openSession(msg.caller, intent, config, sig)) {
      case (#ok(state)) { #ok(state) };
      case (#err(_)) { #err("Failed to open session") };
    };
  };

  public shared(msg) func sessionQuery(
    voucher : Agentflow.Voucher,
    question : Text,
  ) : async { #ok : Text; #error : Text } {
    switch (gate.consumeVoucher(voucher)) {
      case (#ok(_delta)) { #ok(doQuery(question)) };
      case (#insufficientDeposit) { #error("Budget exhausted") };
      case (#policyDenied(r)) { #error("Policy: " # r) };
      case (_) { #error("Invalid voucher") };
    };
  };

  public shared(msg) func endSession(sessionId : Text) : async Agentflow.PaymentResult {
    await gate.closeSession(sessionId);
  };

  // ── Admin ──

  public shared(msg) func withdraw(to : Agentflow.ICRC1.Account, amount : Nat) : async Agentflow.ICRC1.TransferResult {
    assert(Principal.isController(msg.caller));
    // transfer from canister to destination
  };

  // ── Internal ──

  func doSearch(query : Text) : [Text] { ["result1", "result2"] };
  func doQuery(question : Text) : Text { "Answer to: " # question };
};
```

---

## 10. Security

### 10.1 Threat Model

| Threat                  | Mitigation                                                             |
|-------------------------|------------------------------------------------------------------------|
| Charge replay           | Unique nonce per requirement; nonce set tracked, reuse rejected        |
| Voucher replay          | Monotonic sequence number; reject if <= last accepted                  |
| Voucher forgery         | Ed25519 signature bound to payer principal from session open           |
| Over-spending (charge)  | `maxPerTransaction` + `maxPerDay` + ICRC-2 allowance cap              |
| Over-spending (session) | Escrow deposit caps consumption; `maxSessionDeposit` + `maxPerDay`    |
| Session drain           | `sessionIdleTimeout` + `maxSessionDuration` auto-close abandoned sessions |
| Escrow locking          | Unspent deposits auto-refund on close/timeout; admin `forceCloseSession` |
| Prompt injection spend  | Per-day caps + session deposit limits prevent runaway agent spending   |
| Sybil reputation        | ERC-8004 feedback requires proof-of-payment (txHash)                  |
| tECDSA key extraction   | Threshold-distributed across subnet nodes; no single point            |

### 10.2 Nonce Management

- 32-byte random nonce per `PaymentRequirement`
- Bounded nonce set (default 10,000); expired nonces garbage-collected
- Nonces expire with the payment requirement (default 5 minutes)

### 10.3 Upgrade Safety

- All state in stable memory: policies, sessions, nonces, receipts
- Escrow subaccount balances are on-ledger, survive any canister state loss
- `postupgrade` hook reconciles in-flight sessions

---

## 11. Testing

### 11.1 Unit

- Policy evaluation: all combinations, edge cases (at limit, overflow, expiry)
- Voucher verification: valid, replay, out-of-order, over-deposit
- Nonce uniqueness and garbage collection

### 11.2 Integration (local replica)

- Full charge flow: require → approve → settle → receipt
- Full session flow: offer → open → voucher x N → close → receipt + refund
- Session edge cases: exceed deposit, idle timeout, force close, concurrent limit
- Daily aggregate tracking across charges and sessions
- Canister upgrade with active sessions

### 11.3 Cross-chain (testnet)

- ERC-8004 registration on Avalanche Fuji via tECDSA
- Reputation feedback post and query
- Charge settlement on Fuji (stretch)

---

## 12. Future Work

Items cut from MVP, to be pursued post-hackathon:

### 12.1 Privacy Layer

- **vetKeys encrypted receipts**: Encrypt payment receipts using IBE so only sender/recipient can read them. vetKeys is live on ICP mainnet. Medium effort.
- **eERC on Avalanche**: Use Avalanche's Encrypted ERC standard for confidential transfers (zk-SNARK hidden amounts, homomorphic encrypted balances). Significant effort — requires client-side proof generation, eERC contract interaction, wrap/unwrap flow.
- **Encrypted canister state**: Use `ic-vetkeys` `EncryptedMaps` to encrypt payment metadata in stable memory, protecting against subnet node operator reads.

### 12.2 Query-Call Voucher Verification

Use ICP query calls (no consensus, ~200ms) for stateless voucher verification, with batched state updates via canister timers. This would bring voucher latency from ~2s to ~200ms. Trade-off: introduces a trust gap where the server accepts vouchers before recording them on-chain. Acceptable for low-value micropayments; configurable threshold for when to require update calls.

### 12.4 Avalanche L1

Deploy a custom Avalanche L1 (via HyperSDK or Subnet-EVM) optimized for x402 micropayments: near-zero gas, sub-second finality, ERC-8004 registries deployed locally.

### 12.5 Facilitator Canister

Standalone canister that settles payments on behalf of resource servers that don't want to handle settlement themselves. Optional fee model.

### 12.6 CLI Tool

`agentflow init`, `agentflow pay`, `agentflow discover` — developer tooling for testing and managing agentflow-enabled canisters.

---

## Appendix A: Network & Token Registry

| Network           | CAIP-2 ID       |
|-------------------|-----------------|
| ICP Mainnet       | `icp:1`         |
| Avalanche C-Chain | `eip155:43114`  |
| Avalanche Fuji    | `eip155:43113`  |

| Token  | Network   | Identifier                                       | Decimals |
|--------|-----------|--------------------------------------------------|----------|
| ICP    | ICP       | `ryjl3-tyaaa-aaaaa-aaaba-cai`                    | 8        |
| ckUSDC | ICP       | `xevnm-gaaaa-aaaar-qafnq-cai`                    | 6        |
| ckUSDT | ICP       | `cngnf-vqaaa-aaaar-qag4q-cai`                    | 6        |
| USDC   | Avalanche | `0xB97EF9Ef8734C71904D8002F8b6Bc66Dd9c48a6E`     | 6        |
| USDT   | Avalanche | `0x9702230A8Ea53601f5cD2dc00fDBc13d4dF4A8c7`     | 6        |

## Appendix B: Related Standards

- [x402 Protocol](https://www.x402.org)
- [IETF Payment HTTP Auth Scheme](https://datatracker.ietf.org/doc/draft-ryan-httpauth-payment/)
- [ERC-8004: Trustless Agents](https://eips.ethereum.org/EIPS/eip-8004)
- [ERC-8004 Contracts](https://github.com/erc-8004/erc-8004-contracts)
- [ICRC-1 Token Standard](https://github.com/dfinity/ICRC-1)
- [ICRC-2 Approve/TransferFrom](https://github.com/dfinity/ICRC-1/blob/main/standards/ICRC-2/README.md)
- [EIP-3009: Transfer With Authorization](https://eips.ethereum.org/EIPS/eip-3009)
- [CAIP-2: Blockchain ID](https://github.com/ChainAgnostic/CAIPs/blob/main/CAIPs/caip-2.md)
- [vetKeys](https://docs.internetcomputer.org/building-apps/network-features/vetkeys/introduction)
- [eERC (Encrypted ERC)](https://github.com/ava-labs/EncryptedERC)
