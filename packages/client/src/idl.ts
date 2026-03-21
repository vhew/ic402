/// Candid IDL factory for ic402 example canister.
/// Embedded following engramx pattern — no .did file dependency.
import { IDL } from '@icp-sdk/core/candid';

const PaymentRequirement = IDL.Record({
  scheme: IDL.Text,
  network: IDL.Text,
  token: IDL.Text,
  amount: IDL.Nat,
  recipient: IDL.Text,
  nonce: IDL.Vec(IDL.Nat8),
  expiry: IDL.Int,
});

const PaymentSignature = IDL.Record({
  scheme: IDL.Text,
  network: IDL.Text,
  signature: IDL.Vec(IDL.Nat8),
  sender: IDL.Text,
  nonce: IDL.Vec(IDL.Nat8),
});

const PaymentReceipt = IDL.Record({
  id: IDL.Text,
  amount: IDL.Nat,
  token: IDL.Text,
  sender: IDL.Text,
  recipient: IDL.Text,
  network: IDL.Text,
  timestamp: IDL.Int,
  txHash: IDL.Opt(IDL.Text),
  sessionId: IDL.Opt(IDL.Text),
  refunded: IDL.Opt(IDL.Nat),
});

const PaymentResult = IDL.Variant({
  ok: PaymentReceipt,
  insufficientFunds: IDL.Null,
  invalidSignature: IDL.Null,
  expired: IDL.Null,
  policyDenied: IDL.Text,
  tokenNotAccepted: IDL.Null,
  networkNotSupported: IDL.Null,
  settlementFailed: IDL.Text,
  reputationTooLow: IDL.Nat,
  depositBelowMinimum: IDL.Nat,
});

const SessionIntent = IDL.Record({
  network: IDL.Text,
  token: IDL.Text,
  recipient: IDL.Text,
  suggestedDeposit: IDL.Nat,
  minDeposit: IDL.Opt(IDL.Nat),
  expiry: IDL.Int,
  costPerCall: IDL.Opt(IDL.Nat),
  description: IDL.Opt(IDL.Text),
});

const SessionStatus = IDL.Variant({
  open: IDL.Null,
  closing: IDL.Null,
  closed: IDL.Null,
  expired: IDL.Null,
});

const SessionState = IDL.Record({
  id: IDL.Text,
  payer: IDL.Principal,
  deposited: IDL.Nat,
  consumed: IDL.Nat,
  remaining: IDL.Nat,
  voucherCount: IDL.Nat,
  status: SessionStatus,
  openedAt: IDL.Int,
  lastActivityAt: IDL.Int,
});

const SessionConfig = IDL.Record({
  maxDeposit: IDL.Nat,
  autoClose: IDL.Bool,
  idleTimeout: IDL.Opt(IDL.Int),
});

const Voucher = IDL.Record({
  sessionId: IDL.Text,
  cumulativeAmount: IDL.Nat,
  sequence: IDL.Nat,
  signature: IDL.Vec(IDL.Nat8),
});

const SpendingPolicy = IDL.Record({
  maxPerTransaction: IDL.Opt(IDL.Nat),
  maxPerDay: IDL.Opt(IDL.Nat),
  rateLimitPerMinute: IDL.Opt(IDL.Nat),
  maxSessionDeposit: IDL.Opt(IDL.Nat),
  maxConcurrentSessions: IDL.Opt(IDL.Nat),
  maxSessionDuration: IDL.Opt(IDL.Int),
  sessionIdleTimeout: IDL.Opt(IDL.Int),
  allowedCallers: IDL.Opt(IDL.Vec(IDL.Principal)),
  blockedCallers: IDL.Opt(IDL.Vec(IDL.Principal)),
});

// ── Content Delivery ──

const ContentRef = IDL.Record({
  id: IDL.Text,
  mimeType: IDL.Opt(IDL.Text),
  sizeBytes: IDL.Opt(IDL.Nat),
  metadata: IDL.Opt(IDL.Vec(IDL.Tuple(IDL.Text, IDL.Text))),
});

const AccessGrant = IDL.Record({
  grantId: IDL.Text,
  contentRef: ContentRef,
  grantee: IDL.Principal,
  receiptId: IDL.Text,
  issuedAt: IDL.Int,
  expiresAt: IDL.Int,
  hmac: IDL.Vec(IDL.Nat8),
});

const AccessGrantResult = IDL.Variant({
  ok: IDL.Null,
  expired: IDL.Null,
  invalidGrant: IDL.Null,
  revoked: IDL.Null,
});

const DeliveryMethod = IDL.Variant({
  inline: IDL.Vec(IDL.Nat8),
  canisterQuery: IDL.Record({ method: IDL.Text, chunkCount: IDL.Nat }),
  httpUrl: IDL.Text,
  assetCanister: IDL.Record({ canisterId: IDL.Principal, path: IDL.Text }),
});

const ContentDelivery = IDL.Record({
  grant: AccessGrant,
  delivery: DeliveryMethod,
});

const GetContentResult = IDL.Variant({
  paymentRequired: PaymentRequirement,
  ok: ContentDelivery,
  error: IDL.Text,
});

const SearchResult = IDL.Variant({
  paymentRequired: PaymentRequirement,
  ok: IDL.Vec(IDL.Text),
  error: IDL.Text,
});

const OpenSessionResult = IDL.Variant({
  ok: SessionState,
  err: IDL.Text,
});

const SessionQueryResult = IDL.Variant({
  ok: IDL.Text,
  error: IDL.Text,
});

// ── Content Store ──

const ContentEntry = IDL.Record({
  id: IDL.Text,
  mimeType: IDL.Text,
  totalSize: IDL.Nat,
  chunkCount: IDL.Nat,
  createdAt: IDL.Int,
});

const ContentStoreResult = IDL.Variant({
  ok: IDL.Null,
  contentNotFound: IDL.Null,
  chunkNotFound: IDL.Nat,
  contentAlreadyExists: IDL.Null,
  chunkTooLarge: IDL.Nat,
});

export const exampleIdlFactory = () =>
  IDL.Service({
    // Paid service
    search: IDL.Func(
      [IDL.Text, IDL.Opt(PaymentSignature)],
      [SearchResult],
      [],
    ),
    // Sessions
    requestSession: IDL.Func([], [SessionIntent], []),
    openSession: IDL.Func(
      [SessionConfig, PaymentSignature],
      [OpenSessionResult],
      [],
    ),
    sessionQuery: IDL.Func(
      [Voucher, IDL.Text],
      [SessionQueryResult],
      [],
    ),
    endSession: IDL.Func([IDL.Text], [PaymentResult], []),
    // Pattern 1: In-canister content (ContentStore)
    uploadContent: IDL.Func(
      [IDL.Text, IDL.Text, IDL.Vec(IDL.Nat8)],
      [ContentStoreResult],
      [],
    ),
    uploadContentInit: IDL.Func(
      [IDL.Text, IDL.Text, IDL.Nat, IDL.Nat],
      [ContentStoreResult],
      [],
    ),
    uploadContentChunk: IDL.Func(
      [IDL.Text, IDL.Nat, IDL.Vec(IDL.Nat8)],
      [ContentStoreResult],
      [],
    ),
    deleteContent: IDL.Func(
      [IDL.Text],
      [ContentStoreResult],
      [],
    ),
    listContent: IDL.Func(
      [],
      [IDL.Vec(ContentEntry)],
      ['query'],
    ),
    getContent: IDL.Func(
      [IDL.Text, IDL.Opt(PaymentSignature)],
      [GetContentResult],
      [],
    ),
    getChunk: IDL.Func(
      [AccessGrant, IDL.Nat],
      [IDL.Opt(IDL.Vec(IDL.Nat8))],
      ['query'],
    ),
    // Pattern 2: Asset canister
    getAssetContent: IDL.Func(
      [IDL.Text, IDL.Opt(PaymentSignature)],
      [GetContentResult],
      [],
    ),
    // Pattern 3: External (S3/IPFS/Arweave)
    getExternalContent: IDL.Func(
      [IDL.Text, IDL.Opt(PaymentSignature)],
      [GetContentResult],
      [],
    ),
    // Admin
    verifyGrant: IDL.Func(
      [AccessGrant],
      [AccessGrantResult],
      ['query'],
    ),
    setPolicy: IDL.Func([SpendingPolicy], [], []),
    forceCloseSession: IDL.Func([IDL.Text], [PaymentResult], []),
  });

export {
  PaymentRequirement,
  PaymentSignature,
  PaymentReceipt,
  PaymentResult,
  SessionIntent,
  SessionState,
  SessionConfig,
  Voucher,
  SpendingPolicy,
  ContentRef,
  AccessGrant,
  AccessGrantResult,
  DeliveryMethod,
  ContentDelivery,
  GetContentResult,
  ContentEntry,
  ContentStoreResult,
};
