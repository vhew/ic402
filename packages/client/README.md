# @ic402/client

TypeScript client SDK for [ic402](https://github.com/vhew/ic402)-enabled ICP canisters. Handles x402 charge payments, streaming micropayment sessions, EIP-3009 EVM payments, and encrypted content delivery.

## Install

```bash
npm install @ic402/client
```

## Quick Start

### Charge Payment (x402)

```typescript
import { Ic402Client } from '@ic402/client';

const client = new Ic402Client({
  identity,           // @icp-sdk/core Ed25519KeyIdentity
  network: 'icp:1',
  autoPayment: true,
  ledger: 'xevnm-gaaaa-aaaar-qafnq-cai',  // ckUSDC
  canisterId: '<your-canister-id>',
  ledgerActorFactory: (id) => createLedgerActor(id),
});

const result = await client.call(canisterId, 'search', ['query'], actorFactory);
```

### Streaming Session

```typescript
import { Ic402Client } from '@ic402/client';
import { Ed25519KeyIdentity } from '@icp-sdk/core/identity';

const signer = Ed25519KeyIdentity.generate();
const session = await client.openSession(canisterId, {}, actorFactory, {
  sign: (payload) => signer.sign(payload),
  getPublicKey: () => signer.getPublicKey().toRaw(),
});

const answer = await session.call('sessionQuery', ['question']);
console.log(answer, session.remaining);

const receipt = await session.close();
```

### EIP-3009 EVM Payment

```typescript
import { usdcDomain, TRANSFER_WITH_AUTHORIZATION_TYPES, buildTransferAuthorizationMessage } from '@ic402/client';

const message = buildTransferAuthorizationMessage({
  from: payerAddress,
  to: canisterEvmAddress,
  value: 1_000_000n,  // 1 USDC
});

const signature = await walletClient.signTypedData({
  domain: usdcDomain(8453, usdcAddress),
  types: TRANSFER_WITH_AUTHORIZATION_TYPES,
  primaryType: 'TransferWithAuthorization',
  message,
});
```

## API

### `Ic402Client`

| Method | Description |
|--------|-------------|
| `call(canisterId, method, args, actorFactory)` | Call a canister method with auto 402 payment handling |
| `openSession(canisterId, config?, actorFactory?, signer?)` | Open a streaming micropayment session |
| `fetchContent(delivery, options?)` | Fetch content from a `ContentDelivery` response |

### Session Handle

| Property/Method | Description |
|----------------|-------------|
| `id` | Session ID |
| `deposited` | Total deposit amount |
| `consumed` | Amount consumed so far |
| `remaining` | Remaining balance |
| `call(method, args)` | Send a voucher-signed call |
| `callForContent(method, args)` | Send a call expecting `ContentDelivery` |
| `close()` | Close session, settle on-chain, get receipt |

### EIP-712 Helpers

| Export | Description |
|--------|-------------|
| `usdcDomain(chainId, tokenAddress)` | EIP-712 domain for USDC contracts |
| `TRANSFER_WITH_AUTHORIZATION_TYPES` | EIP-712 type definition |
| `buildTransferAuthorizationMessage(params)` | Build the EIP-712 message |
| `buildX402PaymentHeader(network, sig, authz)` | Build X-PAYMENT header |

### Voucher Signing

| Export | Description |
|--------|-------------|
| `signVoucher(signer, sessionId, amount, sequence)` | Sign a cumulative voucher |
| `encodeVoucherPayload(sessionId, amount, sequence)` | CBOR-encode voucher payload |

## Requirements

- Node.js >= 19 (Web Crypto API required)
- `@icp-sdk/core` >= 5.1.0

## License

[Apache-2.0](./LICENSE)
