# @ic402/client

TypeScript client SDK for [ic402](https://github.com/vhew/ic402)-enabled ICP canisters. Handles x402 charge payments (auto 402 → approve → retry), streaming micropayment sessions with Ed25519 vouchers, EIP-3009 EVM payments, encrypted content delivery, the paid-service marketplace, and the client half of the canister's remote EVM signing (canister signs, you broadcast).

## Install

```bash
npm install @ic402/client
```

Requires Node.js ≥ 19 (Web Crypto API) and the peer dependency `@icp-sdk/core` ≥ 5.1.0. Runtime dependencies (`viem`, `cborg`) install automatically.

## Quick start

```ts
import { Actor, HttpAgent } from '@icp-sdk/core/agent';
import { Ic402Client, exampleIdlFactory } from '@ic402/client';

const agent = await HttpAgent.create({ host: 'https://icp-api.io', identity });

const client = new Ic402Client({
  canisterId: '<your-canister-id>',
  actorFactory: (id) => Actor.createActor(exampleIdlFactory, { agent, canisterId: id }),
  identity, // the SAME identity the agent uses
  network: 'icp:1',
  autoPayment: true,
  ledger: 'xevnm-gaaaa-aaaar-qafnq-cai', // ckUSDC
  ledgerActorFactory: (id) => createLedgerActor(id), // any actor exposing icrc2_approve
});

// Trailing [] = the Candid `opt PaymentSignature` argument, empty on the first attempt.
// 402 → ICRC-2 approve → retry with signature → result, all handled for you.
const results = await client.call('search', ['what is x402?', []]);
```

`exampleIdlFactory` matches the reference canister ([`example/main.mo`](https://github.com/vhew/ic402/blob/master/example/main.mo)); pass your own IDL factory for a custom canister.

### Streaming session

```ts
import { Ed25519KeyIdentity } from '@icp-sdk/core/identity';

const voucherKey = Ed25519KeyIdentity.generate();
const session = await client.openSession(
  {},
  {
    sign: (payload) => voucherKey.sign(payload),
    getPublicKey: async () => voucherKey.getPublicKey().toRaw(),
  },
);

const answer = await session.call('sessionQuery', ['question']); // voucher-signed, no on-chain tx
console.log(session.consumed, session.remaining);

const receipt = await session.close(); // settle consumed + refund remainder
```

One escrow deposit on open, one settle on close — every call in between is an Ed25519 voucher the canister verifies in-canister for free.

### EIP-3009 EVM payment

Build and sign the `TransferWithAuthorization` a standard x402 EVM payment needs, with any EIP-712 signer (viem, ethers, MetaMask):

```ts
import {
  usdcDomain,
  TRANSFER_WITH_AUTHORIZATION_TYPES,
  buildTransferAuthorizationMessage,
} from '@ic402/client';

const message = buildTransferAuthorizationMessage({
  from: payerAddress,
  to: canisterEvmAddress, // the 402's `recipient` / `payTo`
  value: 1_000_000n,      // must EQUAL the required amount
});

const signature = await walletClient.signTypedData({
  domain: usdcDomain(8453, usdcAddress),
  types: TRANSFER_WITH_AUTHORIZATION_TYPES,
  primaryType: 'TransferWithAuthorization',
  message,
});
```

Submit the signed authorization either in an x402 `X-PAYMENT` header (HTTP rail) or as the `authorization` field of the Candid `PaymentSignature` your paid method accepts — see the [getting-started walkthrough](https://github.com/vhew/ic402/blob/master/docs/getting-started.md) for the full submission flow.

## API

### `new Ic402Client(config: Ic402ClientConfig)`

| Field | Type | Description |
|-------|------|-------------|
| `canisterId` | `string` | Target canister. **Required.** |
| `actorFactory` | `(canisterId: string) => any` | Creates actors for canister calls. **Required.** |
| `identity` | `Ic402Identity \| null` | Anything with `getPrincipal(): { toText(): string }`; fills the payment `sender`. **Required** (may be `null`). |
| `network` | `string` | CAIP-2 id: `"icp:1"`, `"eip155:84532"`, … **Required.** |
| `autoPayment?` | `boolean` | Auto-handle 402 responses (ICP: ICRC-2 approve + retry). |
| `sessions?` | `SessionPreferences` | Default session preferences. |
| `ledger?` | `string` | Ledger canister id for ICRC-2 auto-approval. |
| `ledgerActorFactory?` | `(ledgerCanisterId: string) => any` | Required for ICP auto-payment. |
| `evmRpcUrl?` | `string` | Custom EVM RPC; defaults to a public RPC per chain. |
| `approvalFeeBuffer?` | `bigint` | Added to ICRC-2 approvals (default `100_000n`). |

### `Ic402Client` methods

| Method | Description |
|--------|-------------|
| `call(method: string, args: unknown[], canisterId?: string): Promise<unknown>` | Call a paid method with auto-402 handling. The method's **last argument must be the `opt PaymentSignature`** — pass `[]` and the client retries with the signature in that slot. Unwraps `{ ok }` variants. |
| `openSession(sessionConfig?: Partial<SessionPreferences>, signer?: VoucherSigner, canisterId?: string): Promise<SessionHandle>` | Open a streaming session: fetch `requestSession()` intent → ICRC-2 approve the deposit (ICP, when `autoPayment`) → `openSession` on the canister. EVM sessions: pass `evmNetwork`/`evmSender`/`authorization` (and optionally `evmTxHash`/`evmToken`/`evmRecipient`) in `sessionConfig`. |
| `fetchContent(delivery: ContentDelivery, options?: { canisterId?: string; actorFactory?: (id: string) => any }): Promise<Uint8Array>` | Fetch paid content for any `DeliveryMethod`: `inline`, `httpUrl`, `assetCanister`, or chunked `canisterQuery` (needs `options`). |
| `fetchX402(url: string, options?: { init?: RequestInit; chainId?: number }): Promise<FetchX402Result>` | Buy from an external x402 API: probe → the canister signs the EIP-3009 header (`signX402Payment`) → retry with `X-Payment`. Requires an `eip155:*` network or explicit `chainId`. |
| `registerAgent(rpcUrl?: string, chainId?: number): Promise<{ tokenId: bigint \| null; txHash: string }>` | ERC-8004 registration: fetch nonce/fees → canister signs → broadcast → poll receipt (throws on revert). |
| `sendErc20Transfer(tokenAddress: string, recipient: string, amount: bigint, rpcUrl?: string): Promise<{ txHash: string }>` | Canister signs an ERC-20 transfer, client broadcasts. |
| `sendEthTransfer(recipient: string, amountWei: bigint, rpcUrl?: string): Promise<{ txHash: string }>` | Canister signs a native transfer, client broadcasts. |
| `listServices(): Promise<ServiceDefinition[]>` | Marketplace service discovery. |
| `submitServiceRequest(serviceId: string, params: Uint8Array): Promise<{ jobId: string }>` | Create a paid job, auto-handling the x402 payment. |
| `pollJobResult(jobId: string, maxAttempts = 30, intervalMs = 2000): Promise<Job>` | Poll until the job settles/verifies (throws on dispute/expiry/refund). |
| `disputeJob(jobId: string, reason: string): Promise<void>` | Dispute a job result (`BuyerConfirm` verification). |
| `discoverAgents(query): Promise<Array<{...}>>` | **Stub** — returns `[]` until ERC-8004 registries carry real agent data. |

### `SessionHandle`

Returned by `openSession`:

| Property / method | Description |
|-------------------|-------------|
| `id` | Session id |
| `deposited` | Escrowed deposit |
| `consumed` / `remaining` | Local accounting, committed only after the canister accepts each voucher |
| `call(method, args)` | Invokes `actor[method](voucher, ...args)` — the signed voucher is prepended as the **first** argument |
| `callForContent(method, args)` | Same, expecting a `ContentDelivery` result |
| `close()` | Calls the canister's `endSession(id)`; returns the settlement `PaymentReceipt` (with `refunded`) |

### Voucher signing

| Export | Signature |
|--------|-----------|
| `signVoucher` | `(signer: VoucherSigner, canisterId: string, sessionId: string, cumulativeAmount: bigint, sequence: bigint) => Promise<Uint8Array>` |
| `encodeVoucherPayload` | `(canisterId: string, sessionId: string, cumulativeAmount: bigint, sequence: bigint) => Uint8Array` |

`encodeVoucherPayload` produces canonical CBOR — `array(4)` of `[canisterId, sessionId, cumulativeAmount, sequence]` — matching the Motoko verifier's field order exactly. The verifying canister's principal is bound into every signature so a voucher for one canister can't be replayed against another. `VoucherSigner` is `{ sign(payload: Uint8Array): Promise<Uint8Array>; getPublicKey(): Promise<Uint8Array> }`.

### EIP-712 helpers

| Export | Description |
|--------|-------------|
| `usdcDomain(chainId: number, tokenAddress: string)` | EIP-712 domain for USDC (Circle FiatTokenV2: name `"USD Coin"`, version `"2"`) |
| `TRANSFER_WITH_AUTHORIZATION_TYPES` | The `TransferWithAuthorization` type definition |
| `buildTransferAuthorizationMessage(params: { from, to, value, validAfter?, validBefore? })` | Builds the message with a cryptographically random `bytes32` nonce; `validBefore` defaults to now + 5 minutes |

### Multi-token (v2.5.0)

The Candid `PaymentSignature` gained an optional `asset` field: the **EVM token contract (the EIP-712 `verifyingContract`) the payer actually signed for**. Omit it (`asset: []`) and the canister settles against the chain's **first configured token** — the pre-2.5.0 behavior, so existing clients keep working unchanged. Set it only when the canister configures more than one token on a chain:

```ts
const paymentSig = {
  // ...scheme, network, sender, nonce, authorization...
  asset: ['0x036CbD53842c5426634e7929541eC2318f3dCF7e'], // the token you signed against
};
```

The signatures this SDK constructs internally (`call`, `submitServiceRequest`, `openSession`) send `asset: []`; sessions key the token off the session intent instead.

### Errors

Failed EVM/x402 flows throw or return `Ic402Error` — `{ kind: Ic402ErrorKind; retryable: boolean; detail?: unknown }`, where `retryable` is true for `transient` and `nonce_error`:

| `Ic402ErrorKind` | Meaning |
|------------------|---------|
| `transient` | Network timeout / RPC rate limit — safe to retry |
| `no_match` | No payment option for the requested chain in the 402 |
| `sign_failed` | Canister refused to sign (policy, frozen, …) |
| `settlement_failed` | Server rejected the signed payment |
| `broadcast_failed` | EVM RPC rejected the transaction |
| `insufficient_funds` | Not enough ETH for gas or USDC for payment |
| `nonce_error` | Nonce too low/high — stale or concurrent tx |
| `not_confirmed` | Broadcast but not confirmed within the poll window |
| `http_error` | Non-402 HTTP error |
| `config_error` | Missing required config (network, chainId, …) |
| `unknown` | Unclassified |

### Lower-level exports

For building custom flows, the pieces behind `fetchX402`/`registerAgent` are exported directly: `probeX402`, `fetchX402` (function form taking a `signPayment` callback), `findPaymentOption`, `applyVerbatimAccepted`, `classifyNetworkError`, `createEvmClient`, `getEvmNonce`, `getFeeData`, `broadcastTransaction`, `pollReceipt`, `parseAgentRegisteredEvent`, `registerAgent` (function form), plus the `exampleIdlFactory` Candid IDL and the full type surface (`PaymentRequirement`, `PaymentReceipt`, `SessionIntent`, `SessionState`, `Voucher`, `ContentDelivery`, `Eip3009Authorization`, `X402PaymentRequirement`, `SignedTransaction`, `SignedAuthorization`, `SignedTypedData`, `ServiceDefinition`, `Job`, `PaymentOption`, `FetchX402Result`, `ProbeResult`, …).

## Requirements

- Node.js ≥ 19 (Web Crypto API required)
- `@icp-sdk/core` ≥ 5.1.0 (peer dependency)

## License

[Apache-2.0](./LICENSE)
