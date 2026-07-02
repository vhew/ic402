# Getting started with ic402

**Who this is for**

- **New users** — go from a clean checkout to your first settled payment on a local replica.
- **Motoko integrators** embedding the library → after this, read the [README quick start](../README.md#quick-start) and treat [`example/main.mo`](../example/main.mo) as the secure baseline to copy (see [`security-model.md`](security-model.md) §2 for why).
- **TypeScript integrators** → after this, read the [`@ic402/client` SDK reference](../packages/client/README.md).

## TL;DR

```bash
git clone https://github.com/vhew/ic402.git && cd ic402
pnpm install        # workspace dependencies
pnpm setup:local    # start local replica, deploy, fund test accounts
pnpm demo           # interactive 10-step walkthrough
```

Then work through the three payment shapes below: a **one-shot x402 charge** (§4), a **streaming session** (§5), and an **EIP-3009 EVM payment** (§6).

## 1. Prerequisites

`pnpm setup:local` preflights the first three and exits with an install pointer if one is missing:

| Tool | Why | Install |
|------|-----|---------|
| `icp` CLI | Runs the local replica, deploys canisters | [internetcomputer.org install guide](https://internetcomputer.org/docs/building-apps/getting-started/install) |
| `pnpm` | Workspace package manager | `npm install -g pnpm` |
| `mops` | Motoko package manager | [mops.one](https://mops.one) |
| Node.js ≥ 22.12 | Runs the demo client and SDK | [nodejs.org](https://nodejs.org) |

## 2. Deploy locally

```bash
pnpm install
pnpm setup:local
```

`setup:local` runs [`scripts/setup.sh`](../scripts/setup.sh), which:

- starts a local ICP replica at `http://localhost:4944`;
- deploys the example canister (`KnowledgeBase`, [`example/main.mo`](../example/main.mo)) and a local **ckUSDC ledger**;
- creates and funds test identities (the payer key lands in `.local/test-payer.pem`);
- builds the TypeScript packages (`@ic402/client`, the MCP server, the demo client).

The library source carries **mainnet** values (real ledger and USDC addresses); the deploy scripts patch them to **testnet** for local development — you never edit the source to develop locally.

## 3. Run the demo

```bash
pnpm demo
```

The interactive demo walks all ten features end-to-end: configure + derive the canister's tECDSA EVM address, upload encrypted content, sell it over x402 (ICP **and** EVM rails), sell async services with escrow + verification, buy from an external x402 API via remote signing, streaming micropayment sessions, ERC-8004 agent identity, EIP-712 delegate signing, and the policy engine.

Everything below is what the demo does, distilled into code you can run yourself.

> **Running the snippets inside this repo:** the root workspace doesn't depend on `@ic402/client`, so replace `from '@ic402/client'` with `from './packages/client/src/index.js'`, save the file at the repo root, and run it with `pnpm exec tsx <file>.ts`. In your own project, `npm install @ic402/client` and keep the imports as written.

## 4. Your first charge (one-shot x402)

The example canister's `search` method costs 1,000 ckUSDC units ($0.001). With `autoPayment` on, the SDK handles the whole 402 dance:

```ts
import { Ic402Client } from '@ic402/client';
import {
  createLocalAgent,
  createExampleActor,
  createLedgerActor,
  getCanisterId,
} from './test/helpers.js';

const agent = await createLocalAgent(); // uses the funded .local/test-payer.pem identity
const principal = await agent.getPrincipal();

const client = new Ic402Client({
  canisterId: getCanisterId('example'),
  actorFactory: (id) => createExampleActor(agent, id),
  identity: { getPrincipal: () => principal }, // must match the agent's identity
  network: 'icp:1',
  autoPayment: true,
  ledger: getCanisterId('ckusdc_ledger'),
  ledgerActorFactory: (id) => createLedgerActor(agent, id),
});

// The trailing [] is the Candid `opt PaymentSignature` — empty on the first call.
const results = await client.call('search', ['what is x402?', []]);
console.log(results);
```

**What's happening:** the first call returns `#paymentRequired` with a single-use server nonce, so the SDK does an ICRC-2 `icrc2_approve` on the ckUSDC ledger and retries with a `PaymentSignature` in the trailing argument — the canister settles via `icrc2_transfer_from` and returns `#ok`. An ICP settle costs the canister <$0.001 in cycles, which is why this rail is the right one for micropayments ([`costs-and-rails.md`](costs-and-rails.md) §3).

## 5. A streaming session

Per-call settlement is wasteful for chatty clients. A session deposits escrow **once**, streams Ed25519-signed vouchers (each ≈ free), and settles **once** on close — 2 on-chain transactions for any number of calls:

```ts
import { Ed25519KeyIdentity } from '@icp-sdk/core/identity';

const voucherKey = Ed25519KeyIdentity.generate(); // per-session signing key

const session = await client.openSession(
  {},
  {
    sign: (payload) => voucherKey.sign(payload),
    getPublicKey: async () => voucherKey.getPublicKey().toRaw(),
  },
);
// Deposits the intent's suggestedDeposit (50,000 units = $0.05 in the example).

const answer = await session.call('sessionQuery', ['what is x402?']); // 500 units/call
console.log(answer, session.consumed, session.remaining);

const receipt = await session.close(); // settles consumed, refunds the rest
console.log('closed:', receipt); // PaymentReceipt — amount settled, `refunded` remainder
```

**What's happening:** `openSession` fetches the canister's `SessionIntent`, ICRC-2-approves the deposit, and registers your Ed25519 public key; each `session.call` signs a cumulative voucher (bound to the session **and** the canister id, so it can't be replayed elsewhere) that the canister verifies in-canister with zero outcalls; `close()` settles the consumed amount and refunds the remainder on the session's rail. This is the "5,000× cheaper" lever quantified in [`costs-and-rails.md`](costs-and-rails.md) §3.

## 6. An EVM payment (EIP-3009)

The same `search` endpoint also advertises EVM payment options — the payer signs a USDC `TransferWithAuthorization` (EIP-3009) and the **canister itself** broadcasts it on-chain via threshold ECDSA. You need a funded EOA holding testnet USDC on a configured chain (the demo uses Base Sepolia), and it must be a **clean** EOA — Circle's USDC rejects EIP-3009 signatures from contract accounts and EIP-7702-delegated EOAs.

```ts
import { usdcDomain, TRANSFER_WITH_AUTHORIZATION_TYPES } from '@ic402/client';
import { privateKeyToAccount } from 'viem/accounts';

const account = privateKeyToAccount(process.env.PAYER_KEY as `0x${string}`);
const actor = createExampleActor(agent, getCanisterId('example'));

// 1. Probe: the 402 advertises ICP + EVM options; pick an EVM one.
const probe = await actor.search('what is x402?', []);
const req = probe.paymentRequired.find((r) => r.network.startsWith('eip155:'));
const chainId = Number(req.network.replace('eip155:', ''));

// 2. Sign an exact-value TransferWithAuthorization with any EIP-712 wallet.
const authNonce = crypto.getRandomValues(new Uint8Array(32));
const validAfter = 0n;
const validBefore = BigInt(Math.floor(Date.now() / 1000) + 300);
const signature = await account.signTypedData({
  domain: usdcDomain(chainId, req.token), // req.tokenName/tokenVersion override the defaults if set
  types: TRANSFER_WITH_AUTHORIZATION_TYPES,
  primaryType: 'TransferWithAuthorization',
  message: {
    from: account.address,
    to: req.recipient,      // the canister's tECDSA-derived EVM address
    value: req.amount,      // must EQUAL the required amount — overpayment is rejected
    validAfter,
    validBefore,
    nonce: ('0x' + Buffer.from(authNonce).toString('hex')) as `0x${string}`,
  },
});

// 3. Split the 65-byte signature into v/r/s and submit as a PaymentSignature.
const sig = Buffer.from(signature.slice(2), 'hex');
const v = sig[64] < 27 ? sig[64] + 27 : sig[64]; // canister expects v ∈ {27, 28}
const paymentSig = {
  scheme: 'exact',
  network: req.network,
  signature: [],
  publicKey: [],
  asset: [], // v2.5.0 multi-token field — [] uses the chain's first configured token
  sender: account.address,
  nonce: req.nonce, // echo the server nonce from step 1
  authorization: [{
    from: account.address,
    to: req.recipient,
    value: req.amount,
    validAfter,
    validBefore,
    nonce: Array.from(authNonce),
    v,
    r: Array.from(sig.subarray(0, 32)),
    s: Array.from(sig.subarray(32, 64)),
  }],
};

const paid = await actor.search('what is x402?', [paymentSig]);
console.log(paid);
```

**What's happening:** the canister recovers the signer from the EIP-712 digest, checks the recipient is its own EVM address and the value exactly equals the bound amount, then broadcasts `transferWithAuthorization` through the EVM RPC canister and waits for on-chain confirmation **before** delivering — a mempool ack is never treated as settlement ([`security-model.md`](security-model.md) §1). The demo's step 3 runs this same flow against paid encrypted content over HTTP, where the signed authorization travels in an `X-PAYMENT` header instead of a Candid argument ([`x402-compliance.md`](x402-compliance.md)).

Two practical notes:

- **Rail economics.** A per-call EVM settle costs the canister ~$0.02–0.10 in cycles plus EVM gas — underwater for a $0.001 charge. Fine for a testnet walkthrough; for real traffic pick the rail by payment size ([`costs-and-rails.md`](costs-and-rails.md) §3).
- **Multi-token chains (v2.5.0).** `asset: []` settles against the chain's **first configured token**. If the canister configures more than one token on a chain, set `asset: ['0x<tokenContract>']` to the EIP-712 `verifyingContract` you actually signed for.

## 7. Where to go next

| Doc | Read it when |
|-----|--------------|
| [`security-model.md`](security-model.md) | **Before mainnet.** The library is not secure-by-default — four access-control checks live only in `example/main.mo`, and the controller key is the whole trust root. |
| [`costs-and-rails.md`](costs-and-rails.md) | Choosing ICP vs EVM vs sessions per payment size; the cycle buffer an operator must hold. |
| [`x402-compliance.md`](x402-compliance.md) | x402 v2 conformance of the EVM rail; the self-hosted facilitator HTTP endpoints (`/verify`, `/settle`, `/supported`, `/discovery/resources`). |
| [`upgrade-safety.md`](upgrade-safety.md) | Upgrading a live canister that embeds ic402's stable state (and holds funds). |
| [`../packages/client/README.md`](../packages/client/README.md) | Full `@ic402/client` API reference. |
| [`../example/main.mo`](../example/main.mo) | The reference wiring for every feature — the baseline to copy, not the README quick start. |
