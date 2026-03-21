# ic402

Everything a canister needs to get paid — x402 charges, streaming sessions, encrypted content, agent discovery.

## Why ICP

A canister is a self-contained service: it holds state, runs compute, signs transactions, and serves HTTP — the canister *is* the server, the wallet, and the relayer, with no external infrastructure required. ic402 adds the payment layer: charge per request, stream micropayments via sessions, and deliver paid content — all within the canister. No external payment processor. No separate storage service. One `import`, one deploy.

For creators: upload content, set a price, get paid directly to your canister's account.
For consumers: discover content, pay with ckUSDC (or any ICRC-2 token), and receive access — all in one canister call.

```motoko
import Ic402 "mo:ic402";

// Core: payment gateway (always included)
let gate = Ic402.Gateway({ /* config */ }, Principal.fromActor(self));

// Optional: encrypted in-canister blob storage
let store = Ic402.ContentStore(Principal.fromActor(self));

// Optional: agent identity for discovery (ERC-8004)
let id = Ic402.Identity({ chain = #base; card = myAgentCard });
```

## What ic402 does

| Capability | Description |
|------------|-------------|
| **Charge** (x402) | One-time payment per request |
| **Sessions** | Escrow deposit + streaming micropayments |
| **Policy engine** | Spending limits, rate limits, daily caps |
| **Access grants** | Cryptographic proof-of-payment tokens |
| **ContentStore** (optional) | Encrypted in-canister blob storage with chunking |
| **Identity** (optional) | ERC-8004 agent cards for on-chain discovery |

## For creators: getting paid

### Paid services (no content hosting)

The Gateway handles payment for any canister endpoint. No storage needed — just charge per call.

```motoko
public shared func search(query : Text, sig : ?Ic402.PaymentSignature)
  : async { #paymentRequired : Ic402.PaymentRequirement; #ok : [Text]; #error : Text }
{
  let price = { token = ckusdcLedger; amount = 50_000; network = "icp:1" };
  switch (sig) {
    case (null) { #paymentRequired(gate.require(price)) };
    case (?s) {
      switch (await gate.settle(s)) {
        case (#ok(_)) { #ok(doSearch(query)) };
        case (_) { #paymentRequired(gate.require(price)) };
      };
    };
  };
};
```

### Paid content

Three hosting patterns — pick the one that fits:

| Pattern | Where content lives | When to use |
|---------|-------------------|-------------|
| **In-canister** (ContentStore) | Canister memory, encrypted at rest | Small catalogs, fully on-chain, maximum privacy |
| **Asset canister** | Separate ICP canister | Large file sets, HTTP gateway serving, CDN-like delivery |
| **External** (S3/IPFS/Arweave) | Off-chain | Existing infrastructure, large media, permanent storage |

#### In-canister (ContentStore)

Content is encrypted at rest using SHA-256-CTR. Combined with ICP's subnet-level memory protection, this provides two layers of privacy: node operators can't read canister memory, and even raw memory snapshots contain only ciphertext.

```motoko
// ContentStore is OPTIONAL — import only if hosting content in-canister
transient let store = Ic402.ContentStore(Principal.fromActor(self));

// Upload (admin only — encrypted automatically)
ignore store.put("doc-001", "text/plain", myBlob);

// Deliver after payment
let ?blob = store.get(contentId);
let grant = gate.issueGrant(contentRef, caller, receipt.id, ttl);
#ok({ grant; delivery = #inline(blob) });
```

#### Asset canister

Content lives in a separate ICP canister served via the HTTP gateway. For sensitive content, encrypt files before uploading — return the decryption key on payment.

```motoko
let grant = gate.issueGrant(contentRef, caller, receipt.id, ttl);
#ok({ grant; delivery = #assetCanister({ canisterId = myAssets; path = assetPath }) });
```

#### External (S3 / IPFS / Arweave)

Content lives off-chain. Generate pre-signed URLs (via tECDSA) or return decryption keys on payment.

```motoko
let grant = gate.issueGrant(contentRef, caller, receipt.id, ttl);
#ok({ grant; delivery = #httpUrl(presignedUrl) });
```

See `src/example/main.mo` for full working implementations of all three patterns with detailed encryption guidance.

## For consumers: paying for content

The TypeScript client SDK handles the payment flow automatically — discover, pay, and fetch content in a few lines.

```typescript
import { Ic402Client } from '@ic402/client';

const client = new Ic402Client({
  identity: myIdentity,
  network: 'icp:1',
  autoPayment: true,
  budget: {
    maxPerRequest: 100_000n,   // max per call
    maxPerDay: 10_000_000n,    // daily cap
    maxTotal: 50_000_000n,     // lifetime cap
  },
});

// Pay for a service call (auto-handles 402 → approve → retry)
const results = await client.call(canisterId, 'search', ['my query'], actorFactory);

// Pay for content (any delivery method: inline, httpUrl, canisterQuery, assetCanister)
const delivery = await client.call(canisterId, 'getContent', ['doc-001'], actorFactory);
const bytes = await client.fetchContent(delivery, { canisterId, actorFactory });

// Streaming session — deposit once, pay per call with zero on-chain cost
const session = await client.openSession(canisterId, {}, actorFactory, mySigner);
const a1 = await session.call('sessionQuery', ['what is X?']);
const a2 = await session.call('sessionQuery', ['what is Y?']);
const receipt = await session.close(); // settle consumed, refund remainder
```

### Budget protection

The client enforces budget limits before approving any payment:

```typescript
budget: {
  maxPerRequest: 100_000n,      // reject if single call costs more
  maxPerDay: 10_000_000n,       // rolling 24h cap
  maxTotal: 50_000_000n,        // lifetime cap
  maxSessionDeposit: 5_000_000n, // max escrow per session
  alertThreshold: 8_000_000n,   // callback when 80% spent
}
```

## Identity (optional)

The Identity module provides ERC-8004 agent cards for on-chain discovery. Other agents can find your canister by querying the IdentityRegistry contract on supported EVM chains.

```motoko
transient let id = Ic402.Identity({
  chain = #base;
  card = {
    name = "KnowledgeBase";
    description = "Paid knowledge base with 10k documents";
    services = [{
      name = "search";
      endpoint = "https://<canisterId>.icp0.io";
      version = "1.0";
      skills = ["search", "qa"];
      domains = ["science", "engineering"];
    }];
    x402Support = true;
  };
});

// Register on-chain (returns agent ID)
let agentId = await id.registerAgent();

// Query the card
let card = id.getCard();
```

On the consumer side, the client SDK can discover agents:

```typescript
const agents = await client.discoverAgents({
  chain: 'eip155:8453', // Base
  skills: ['search'],
  x402Support: true,
});
```

## Why sessions

A pure x402 charge model requires one on-chain transaction per API call. Even on ICP (~$0.0001/tx), an agent making 10,000 calls/day pays $1 in settlement overhead alone. With sessions, those 10,000 calls settle in exactly 2 transactions (deposit + close), costing ~$0.0002 total — a **5,000x reduction**.

| Feature                           | x402-icp               | Anda Facilitator        | ic402     |
|-----------------------------------|------------------------|-------------------------|-----------|
| Charge (one-time)                 | Yes                    | Yes                     | Yes       |
| Session (streaming micropayments) | No                     | No                      | **Yes**   |
| Policy engine (caps, rate limits) | No                     | No                      | **Yes**   |
| Drop-in canister library          | No (Express middleware) | No (standalone canister) | **Yes**   |

## Architecture

```
┌────────────────────────────────────────────────────────────┐
│                        Your Canister                       │
│                                                            │
│   import Ic402 "mo:ic402"                                  │
│                                                            │
│   ┌────────────┐  ┌────────────┐  ┌──────────────────┐    │
│   │  Charge    │  │  Session   │  │  Policy Engine   │    │
│   │  (x402)    │  │  (Escrow + │  │  (limits, rates, │    │
│   │            │  │  Vouchers) │  │   daily caps)    │    │
│   └─────┬──────┘  └─────┬──────┘  └────────┬─────────┘    │
│         │               │                  │              │
│   ┌─────▼───────────────▼──────────────────▼──────────┐   │
│   │              ICRC-2 Settlement                    │   │
│   └───────────────────────────────────────────────────┘   │
│                                                            │
│   ┌ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ┐  ┌ ─ ─ ─ ─ ─ ─ ─ ─ ─ ┐  │
│   │  ContentStore (optional) │  │  Identity (optional)│  │
│   │  Encrypted blob storage  │  │  ERC-8004 agent     │  │
│   └ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ┘  │  cards & discovery  │  │
│                                  └ ─ ─ ─ ─ ─ ─ ─ ─ ─ ┘  │
└────────────────────────────────────────────────────────────┘
```

**Core** (always included): Gateway handles charges, sessions, policy, and access grants.

**Optional modules** — import only what you need:
- **ContentStore** — encrypted in-canister blob storage with auto-chunking
- **Identity** — ERC-8004 agent cards for on-chain discovery

## Quick start

### Prerequisites

- [ICP SDK](https://internetcomputer.org/docs/building-apps/getting-started/install) (icp CLI)
- [mops](https://mops.one) (Motoko package manager)
- [Node.js](https://nodejs.org/) >= 22.12.0
- [pnpm](https://pnpm.io/) >= 9

### Install

```bash
mops add ic402
```

### Minimal canister (paid service)

```motoko
import Ic402 "mo:ic402";
import Principal "mo:base/Principal";

persistent actor MyService {

  var stableGateway : ?Ic402.StableGatewayState = null;

  transient let gate = Ic402.Gateway(
    {
      recipient = { owner = Principal.fromActor(MyService); subaccount = null };
      tokens = [{ ledger = Principal.fromText("xevnm-gaaaa-aaaar-qafnq-cai"); symbol = "ckUSDC"; decimals = 6 }];
      avalanche = null;
    },
    Principal.fromActor(MyService),
  );

  do { switch (stableGateway) { case (?d) { gate.loadStable(d) }; case (null) {} } };
  gate.startTimers<system>();
  system func preupgrade() { stableGateway := ?gate.toStable() };
  system func postupgrade() { stableGateway := null };

  public shared func myEndpoint(sig : ?Ic402.PaymentSignature)
    : async { #paymentRequired : Ic402.PaymentRequirement; #ok : Text; #error : Text }
  {
    let price = { token = Principal.fromText("xevnm-gaaaa-aaaar-qafnq-cai"); amount = 50_000; network = "icp:1" };
    switch (sig) {
      case (null) { #paymentRequired(gate.require(price)) };
      case (?s) {
        switch (await gate.settle(s)) {
          case (#ok(_)) { #ok("paid result") };
          case (_) { #paymentRequired(gate.require(price)) };
        };
      };
    };
  };
};
```

### Content canister (paid content)

```motoko
import Ic402 "mo:ic402";
import Principal "mo:base/Principal";

persistent actor MyContent {

  var stableGateway : ?Ic402.StableGatewayState = null;
  var stableContent : ?Ic402.StableContentStoreState = null;

  transient let gate = Ic402.Gateway({ /* config */ }, Principal.fromActor(MyContent));
  transient let store = Ic402.ContentStore(Principal.fromActor(MyContent));

  do {
    switch (stableGateway) { case (?d) { gate.loadStable(d) }; case (null) {} };
    switch (stableContent) { case (?d) { store.loadStable(d) }; case (null) {} };
  };
  gate.startTimers<system>();
  system func preupgrade() { stableGateway := ?gate.toStable(); stableContent := ?store.toStable() };
  system func postupgrade() { stableGateway := null; stableContent := null };

  public shared(msg) func uploadContent(id : Text, mimeType : Text, data : Blob) : async Ic402.ContentStoreResult {
    assert(Principal.isController(msg.caller));
    store.put(id, mimeType, data);
  };

  public shared(msg) func getContent(id : Text, sig : ?Ic402.PaymentSignature) : async {
    #paymentRequired : Ic402.PaymentRequirement; #ok : Ic402.ContentDelivery; #error : Text;
  } {
    let price = { token = Principal.fromText("xevnm-gaaaa-aaaar-qafnq-cai"); amount = 100_000; network = "icp:1" };
    switch (sig) {
      case (null) { #paymentRequired(gate.require(price)) };
      case (?s) {
        switch (await gate.settle(s)) {
          case (#ok(receipt)) {
            let ?ref = store.toContentRef(id) else return #error("Not found");
            let ?blob = store.get(id) else return #error("Read failed");
            let grant = gate.issueGrant(ref, msg.caller, receipt.id, 5 * 60 * 1_000_000_000);
            #ok({ grant; delivery = #inline(blob) });
          };
          case (_) { #paymentRequired(gate.require(price)) };
        };
      };
    };
  };
};
```

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

## Policy engine

The policy engine enforces spending limits, rate limiting, and access control — all evaluated in-canister with no ledger calls.

```motoko
gate.setPolicy(null, {               // global defaults
  maxPerTransaction = ?1_000_000;     // max per charge/voucher
  maxPerDay = ?10_000_000;            // rolling 24h cap
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
| `issueGrant(contentRef, grantee, receiptId, ttl)` | Issue a proof-of-payment access grant |
| `verifyGrant(grant)` | HMAC verify + expiry + revocation check |
| `revokeGrant(grantId)` | Revoke a grant (e.g., after refund) |
| `toStable() / loadStable()` | Serialize/deserialize state for canister upgrades |

### ContentStore (optional)

Import only if hosting content in-canister. Encrypts all content at rest.

| Method | Description |
|--------|-------------|
| `put(id, mimeType, data)` | Encrypt + store blob, auto-chunk at 1.5 MB |
| `putChunkedInit(id, mimeType, totalSize, chunkCount)` | Initialize a multi-chunk upload |
| `putChunk(id, index, data)` | Encrypt + upload one chunk |
| `get(id)` | Retrieve + decrypt full blob (reassembles chunks) |
| `getChunk(id, index)` | Retrieve + decrypt single chunk |
| `getMetadata(id)` | Metadata without blob data |
| `list()` | All entries metadata |
| `delete(id)` | Remove entry |
| `toContentRef(id)` | Bridge to Gateway.issueGrant() |
| `toStable() / loadStable()` | Serialize/deserialize (data stays encrypted) |

### Identity (optional)

Import only if your canister needs to be discoverable as an agent via ERC-8004.

| Method | Description |
|--------|-------------|
| `getCard()` | Get the agent card metadata |
| `getChain()` | Get the target EVM chain |
| `getAgentId()` | Get the registered agent ID (if registered) |
| `registerAgent()` | Register on ERC-8004 IdentityRegistry (stub — tECDSA post-hackathon) |
| `toStable() / loadStable()` | Serialize/deserialize state |

### Client SDK

| Method | Description |
|--------|-------------|
| `call(canisterId, method, args, actorFactory)` | Call a canister method, auto-handling 402 payment |
| `openSession(canisterId, config?, actorFactory?, signer?)` | Open a session, returns a `SessionHandle` |
| `SessionHandle.call(method, args)` | Call through session with auto-signed voucher |
| `SessionHandle.callForContent(method, args)` | Call that returns `ContentDelivery` |
| `SessionHandle.close()` | Close session, settle and refund |
| `fetchContent(delivery, options?)` | Fetch bytes from any delivery method |
| `discoverAgents(query)` | Find agents via ERC-8004 registries |

## CLI testing

With the local replica running:

```bash
# Paid service — returns paymentRequired
icp canister call example search '("test query", null)' -e local

# Session flow
icp canister call example requestSession '()' -e local

# Content Store — upload, list, get, delete
icp canister call example uploadContent '("doc-001", "text/plain", blob "Hello!")' -e local
icp canister call example listContent '()' -e local
icp canister call example getContent '("doc-001", null)' -e local
icp canister call example deleteContent '("doc-001")' -e local

# Asset canister pattern
icp canister call example getAssetContent '("/images/hero.png", null)' -e local

# External pattern
icp canister call example getExternalContent '("report-2024.pdf", null)' -e local
```

## Development

### Local setup

```bash
./scripts/local-start.sh
```

### Build

```bash
mops install            # Motoko dependencies
pnpm install            # Node dependencies
icp build               # Build Motoko canisters
pnpm build:client       # Build TypeScript client
```

### Test

```bash
# Motoko unit tests (Policy, Nonce, Grants, ContentStore)
mops test

# Integration tests (requires running local replica)
pnpm test:integration

# Full local test suite (CLI + unit + integration)
./deploy/local-test.sh
```

### Regenerating the Candid interface

```bash
./scripts/gen-did.sh
```

## Project structure

```
src/ic402/
  lib.mo             Entry point — re-exports types & classes
  Types.mo           All type definitions
  Gateway.mo         Core gateway (charge, session, policy, access grants)
  ContentStore.mo    Optional: encrypted blob storage (put, get, chunking)
  Identity.mo        Optional: ERC-8004 agent cards and registration
  Policy.mo          Spending limits, rate limiting, access control
  Nonce.mo           Replay protection (SHA-256 nonces with expiry)
  Escrow.mo          ICRC-2 escrow subaccount management
src/example/
  main.mo            Example canister — paid service + three content patterns
  example.did        Generated Candid interface
packages/client/
  src/client.ts      Ic402Client — TypeScript SDK
  src/voucher.ts     Ed25519 voucher signing & CBOR encoding
  src/types.ts       TypeScript mirrors of Motoko types
  src/idl.ts         Candid IDL definitions
integration/
  mcp/               MCP server — exposes ic402 as AI tool-use endpoints
test/
  contentstore.test.mo  Unit tests for ContentStore
  grant.test.mo         Unit tests for Access Grants
  policy.test.mo        Unit tests for Policy engine
  nonce.test.mo         Unit tests for Nonce manager
deploy/
  local-test.sh      Full local test suite
  smoke-test.sh      Post-deploy verification
```

## Status

MVP / hackathon build. Core payment flows and content delivery are functional. Known limitations:

- Voucher signature verification is stubbed (Ed25519 verify not yet wired up on-chain)
- ICRC-2 auto-approval in the TypeScript client is not yet implemented
- ERC-8004 agent identity registration requires tECDSA (post-hackathon)
- ContentStore encryption uses SHA-256-CTR (adequate for subnet-level protection)

See the [full specification](docs/SPEC.md) for detailed design, security model, and future roadmap.

## License

[Apache 2.0](LICENSE)
