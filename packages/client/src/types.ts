/// Mirrors the Motoko types from src/ic402/Types.mo.

export interface PaymentRequirement {
  scheme: string;
  network: string;
  token: string;
  amount: bigint;
  recipient: string;
  nonce: Uint8Array;
  expiry: bigint;
}

export interface PaymentReceipt {
  id: string;
  amount: bigint;
  token: string;
  sender: string;
  recipient: string;
  network: string;
  timestamp: bigint;
  txHash?: string;
  sessionId?: string;
  refunded?: bigint;
}

export interface SessionIntent {
  network: string;
  token: string;
  recipient: string;
  suggestedDeposit: bigint;
  minDeposit?: bigint;
  expiry: bigint;
  costPerCall?: bigint;
  description?: string;
}

export interface SessionState {
  id: string;
  deposited: bigint;
  consumed: bigint;
  remaining: bigint;
  voucherCount: bigint;
  status: 'open' | 'closing' | 'closed' | 'expired';
  openedAt: bigint;
  lastActivityAt: bigint;
}

export interface Voucher {
  sessionId: string;
  cumulativeAmount: bigint;
  sequence: bigint;
  signature: Uint8Array;
}

// ── EIP-3009 Authorization (standard x402 EVM payments) ──

export interface Eip3009Authorization {
  from: string; // payer EVM address (0x-prefixed)
  to: string; // recipient EVM address
  value: bigint; // USDC amount
  validAfter: bigint; // unix timestamp
  validBefore: bigint;
  nonce: Uint8Array; // random bytes32
  v: number;
  r: Uint8Array; // 32 bytes
  s: Uint8Array; // 32 bytes
}

// x402 v1 payment requirement (from 402 response)
export interface X402PaymentRequirement {
  scheme: string;
  network: string;
  asset: string; // token contract address
  maxAmountRequired: string; // amount as decimal string
  payTo: string; // recipient address
  maxTimeoutSeconds: number;
  extra?: { name: string; version: string };
}

// ── Content Delivery ──

export interface ContentRef {
  id: string;
  mimeType?: string;
  sizeBytes?: bigint;
  metadata?: [string, string][];
}

export interface AccessGrant {
  grantId: string;
  contentRef: ContentRef;
  grantee: string;
  receiptId: string;
  issuedAt: bigint;
  expiresAt: bigint;
  hmac: Uint8Array;
}

export type AccessGrantResult =
  | { ok: null }
  | { expired: null }
  | { invalidGrant: null }
  | { revoked: null };

export type DeliveryMethod =
  | { inline: Uint8Array }
  | { canisterQuery: { method: string; chunkCount: bigint } }
  | { httpUrl: string }
  | { assetCanister: { canisterId: string; path: string } };

export interface ContentDelivery {
  grant: AccessGrant;
  delivery: DeliveryMethod;
}

// ── Content Store ──

export interface ContentEntry {
  id: string;
  mimeType: string;
  totalSize: bigint;
  chunkCount: bigint;
  createdAt: bigint;
}

export type ContentStoreResult =
  | { ok: null }
  | { contentNotFound: null }
  | { chunkNotFound: bigint }
  | { contentAlreadyExists: null }
  | { chunkTooLarge: bigint };
