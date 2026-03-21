# agentflow

Drop-in payment library for ICP canisters. x402 charges, streaming sessions, policy engine.

**agent** — autonomous AI agents that discover, pay, and transact without human intervention.
**flow** — the continuous stream of micropayments between them, settled via sessions, not individual transactions.

agentflow is a Motoko library that any ICP canister can import to accept payments via x402, with a streaming session model that makes micropayments economical, and an extensible policy engine for spending control.

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

## Why sessions

A pure x402 charge model requires one on-chain transaction per API call. Even on ICP (~$0.0001/tx), an agent making 10,000 calls/day pays $1 in settlement overhead alone. With sessions, those 10,000 calls settle in exactly 2 transactions (deposit + close), costing ~$0.0002 total — a **5,000x reduction**.

| Feature                           | x402-icp              | Anda Facilitator        | agentflow |
|-----------------------------------|-----------------------|-------------------------|-----------|
| Charge (one-time)                 | Yes                   | Yes                     | Yes       |
| Session (streaming micropayments) | No                    | No                      | **Yes**   |
| Policy engine (caps, rate limits) | No                    | No                      | **Yes**   |
| Drop-in canister library          | No (Express middleware)| No (standalone canister)| **Yes**   |

## Architecture

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
└──────────────────────────────────────────────────────────┘
```

Three core components, all running inside your canister:

1. **Charge** — x402 "exact" scheme. One ICRC-2 transfer per request.
2. **Session** — ICRC-2 escrow deposit + cumulative vouchers. One settlement on close.
3. **Policy Engine** — Per-caller limits, daily caps, rate limits. Runs in-canister for free.

## Payment models

### Charge (x402)

One-time atomic payment per request. The canister returns a 402 with a `PaymentRequirement`, the client approves via ICRC-2, then retries with a `PaymentSignature`.

```
Client                   Canister                    ICRC-2 Ledger
  │── request ──────────>│                               │
  │<── 402 + requirement │                               │
  │── icrc2_approve ────────────────────────────────────>│
  │── request + sig ────>│── verify + transfer_from ────>│
  │<── 200 + receipt ────│                               │
```

**When to use:** Infrequent calls, amounts > $0.01, simple integration.

### Session (escrow + vouchers)

The client deposits funds into an escrow subaccount once, then signs lightweight vouchers per call with zero on-chain cost. On session close, consumed funds settle to the service and the remainder refunds to the caller.

```
Client                   Canister                    ICRC-2 Ledger
  │── requestSession ───>│                               │
  │<── SessionIntent ────│                               │
  │── icrc2_approve ────────────────────────────────────>│
  │── openSession + sig >│── transfer_from (escrow) ────>│
  │<── SessionState ─────│                               │
  │                      │                               │
  │── voucher + call ───>│── verify voucher (free)       │
  │<── response ─────────│                               │
  │── voucher + call ───>│── verify voucher (free)       │
  │<── response ─────────│  ... ×N (no on-chain cost)    │
  │                      │                               │
  │── endSession ───────>│── settle consumed ───────────>│
  │                      │── refund remainder ──────────>│
  │<── receipt ──────────│                               │
```

Vouchers are **cumulative** — each voucher declares the total spent so far, not the delta. Monotonically increasing sequences prevent replay. The canister verifies vouchers in constant time with no ledger calls.

**When to use:** High-frequency calls, micropayments < $0.01, long-running agent tasks.

## Quick start

### Prerequisites

- [ICP SDK](https://internetcomputer.org/docs/building-apps/getting-started/install) (icp CLI)
- [mops](https://mops.one) (Motoko package manager)
- [Node.js](https://nodejs.org/) >= 22.12.0
- [pnpm](https://pnpm.io/) >= 9

### Install the library

```bash
mops add agentflow
```

### Canister setup

```motoko
import Agentflow "mo:agentflow";
import Principal "mo:base/Principal";

persistent actor MyService {

  var stableGateway : ?Agentflow.StableGatewayState = null;

  transient let gate = Agentflow.Gateway(
    {
      recipient = { owner = Principal.fromActor(MyService); subaccount = null };
      tokens = [{
        ledger = Principal.fromText("xevnm-gaaaa-aaaar-qafnq-cai"); // ckUSDC
        symbol = "ckUSDC";
        decimals = 6;
      }];
      erc8004 = null;
      avalanche = null;
    },
    Principal.fromActor(MyService),
  );

  // Load stable state on init
  do {
    switch (stableGateway) {
      case (?data) { gate.loadStable(data) };
      case (null) {};
    };
  };

  // Set spending policy
  do {
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
  };

  gate.startTimers<system>();

  system func preupgrade() { stableGateway := ?gate.toStable() };
  system func postupgrade() { stableGateway := null };

  // Charge endpoint — 0.05 ckUSDC per search
  public shared func search(query : Text, sig : ?Agentflow.PaymentSignature)
    : async { #paymentRequired : Agentflow.PaymentRequirement; #ok : [Text]; #error : Text }
  {
    let price : Agentflow.Price = {
      token = Principal.fromText("xevnm-gaaaa-aaaar-qafnq-cai");
      amount = 50_000; // 0.05 ckUSDC (6 decimals)
      network = "icp:1";
    };
    switch (sig) {
      case (null) { #paymentRequired(gate.require(price)) };
      case (?s) {
        switch (await gate.settle(s)) {
          case (#ok(_)) { #ok(["result 1", "result 2"]) };
          case (#policyDenied(r)) { #error("Policy: " # r) };
          case (_) { #paymentRequired(gate.require(price)) };
        };
      };
    };
  };

  // Session endpoints
  public shared func requestSession() : async Agentflow.SessionIntent {
    gate.offerSession({
      network = "icp:1";
      token = Principal.toText(Principal.fromText("xevnm-gaaaa-aaaar-qafnq-cai"));
      recipient = Principal.toText(Principal.fromActor(MyService));
      suggestedDeposit = 1_000_000;
      minDeposit = ?100_000;
      expiry = 0; // set from Time.now() in practice
      costPerCall = ?1_000;
      description = ?"Pay-per-query session";
    });
  };

  public shared(msg) func openSession(config : Agentflow.SessionConfig, sig : Agentflow.PaymentSignature)
    : async { #ok : Agentflow.SessionState; #err : Text }
  {
    let intent = await requestSession();
    switch (await gate.openSession(msg.caller, intent, config, sig)) {
      case (#ok(state)) { #ok(state) };
      case (#err(e)) { #err("Failed to open session") };
    };
  };

  public shared func sessionQuery(voucher : Agentflow.Voucher, question : Text)
    : async { #ok : Text; #error : Text }
  {
    switch (gate.consumeVoucher(voucher)) {
      case (#ok(_)) { #ok("Answer to: " # question) };
      case (#insufficientDeposit) { #error("Budget exhausted") };
      case (_) { #error("Invalid voucher") };
    };
  };

  public shared func endSession(sessionId : Text) : async Agentflow.PaymentResult {
    await gate.closeSession(sessionId);
  };
};
```

### TypeScript client

```bash
pnpm add @agentflow/client
```

```typescript
import { AgentflowClient } from '@agentflow/client';

const client = new AgentflowClient({
  identity: myIdentity,
  network: 'icp:1',
  autoPayment: true,
  budget: {
    maxPerRequest: 100_000n,
    maxPerDay: 10_000_000n,
  },
});

// One-time charge
const results = await client.call(canisterId, 'search', ['my query'], actorFactory);

// Streaming session
const session = await client.openSession(canisterId, {}, actorFactory, mySigner);
const answer1 = await session.call('sessionQuery', ['what is X?']);
const answer2 = await session.call('sessionQuery', ['what is Y?']);
const receipt = await session.close(); // settles + refunds remainder
```

## Policy engine

The policy engine enforces spending limits, rate limiting, and access control — all evaluated in-canister with no ledger calls.

```motoko
gate.setPolicy(null, {               // global defaults
  maxPerTransaction = ?1_000_000;     // max per charge/voucher
  maxPerDay = ?10_000_000;            // rolling 24h cap (charges + sessions)
  rateLimitPerMinute = ?120;          // requests per minute per caller
  maxSessionDeposit = ?5_000_000;     // max escrow per session
  maxConcurrentSessions = ?1;         // active sessions per caller
  maxSessionDuration = ?86_400_000_000_000; // 24h in nanoseconds
  sessionIdleTimeout = ?3_600_000_000_000;  // 1h idle timeout
  allowedCallers = null;              // whitelist (null = allow all)
  blockedCallers = null;              // blacklist
});

// Per-caller override
gate.setPolicy(?somePrincipal, { /* higher limits for trusted caller */ });
```

Policy checks cascade: access control → rate limit → per-transaction limit → daily limit.

## API reference

### Gateway

| Method | Description |
|--------|-------------|
| `require(price)` | Generate a `PaymentRequirement` with a 5-minute nonce |
| `settle(signature)` | Verify nonce, check policy, execute ICRC-2 `transfer_from` |
| `offerSession(intent)` | Return a `SessionIntent` for the client to negotiate |
| `openSession(caller, intent, config, sig)` | Deposit escrow, create session, return `SessionState` |
| `consumeVoucher(voucher)` | Verify voucher sequence & cumulative amount, record spend |
| `getSession(sessionId)` | Query session state |
| `closeSession(sessionId)` | Settle consumed amount, refund remainder |
| `closeExpiredSessions()` | Close all idle/expired sessions (also runs on a 60s timer) |
| `setPolicy(caller?, policy)` | Set global or per-caller spending policy |
| `getPolicy(caller)` | Get effective policy for a caller |
| `dailySpend(caller)` | Query rolling 24h spend |
| `toStable() / loadStable()` | Serialize/deserialize state for canister upgrades |

### Client SDK

| Method | Description |
|--------|-------------|
| `call(canisterId, method, args, actorFactory)` | Call a canister method, auto-handling 402 payment |
| `openSession(canisterId, config?, actorFactory?, signer?)` | Open a session, returns a `SessionHandle` |
| `SessionHandle.call(method, args)` | Call through session with auto-signed voucher |
| `SessionHandle.close()` | Close session, settle and refund |

## Development

### Local setup

```bash
./scripts/local-start.sh
```

This installs dependencies, starts a local ICP replica on port 4944, and deploys the example canister with a local ckUSDC ledger.

### Build

```bash
mops install            # Motoko dependencies
pnpm install            # Node dependencies
icp build               # Build Motoko canisters
pnpm build:client       # Build TypeScript client
```

### Test

```bash
# Motoko unit tests (Policy, Nonce)
mops test

# Integration tests (requires running local replica)
pnpm test:integration

# Client SDK tests
pnpm test:client
```

### Lint & format

```bash
pnpm lint
pnpm format:check
```

## Project structure

```
src/agentflow/
  lib.mo          Entry point — re-exports types & classes
  Types.mo        All type definitions
  Gateway.mo      Main payment gateway (charge, session, policy)
  Policy.mo       Spending limits, rate limiting, access control
  Nonce.mo        Replay protection (SHA-256 nonces with expiry)
  Escrow.mo       ICRC-2 escrow subaccount management
src/example/
  main.mo         Example canister with charge & session endpoints
packages/client/
  src/client.ts   AgentflowClient — TypeScript SDK
  src/voucher.ts  Ed25519 voucher signing & CBOR encoding
  src/types.ts    TypeScript mirrors of Motoko types
test/
  integration.test.ts   End-to-end tests against local replica
  policy.test.mo        Motoko unit tests for Policy engine
  nonce.test.mo         Motoko unit tests for Nonce manager
```

## Status

This is an MVP / hackathon build. Core payment flows (charge, session, policy) are functional. Known limitations:

- Voucher signature verification is stubbed (Ed25519 verify not yet wired up on-chain)
- ICRC-2 auto-approval in the TypeScript client is not yet implemented
- ERC-8004 agent identity registration requires tECDSA (post-hackathon)

See the [full specification](docs/SPEC.md) for detailed design, security model, and future roadmap.

## License

[Apache 2.0](LICENSE)
