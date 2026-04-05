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
  tokenName: IDL.Opt(IDL.Text),
  tokenVersion: IDL.Opt(IDL.Text),
});

const Eip3009Authorization = IDL.Record({
  from: IDL.Text,
  to: IDL.Text,
  value: IDL.Nat,
  validAfter: IDL.Nat,
  validBefore: IDL.Nat,
  nonce: IDL.Vec(IDL.Nat8),
  v: IDL.Nat8,
  r: IDL.Vec(IDL.Nat8),
  s: IDL.Vec(IDL.Nat8),
});

const PaymentSignature = IDL.Record({
  scheme: IDL.Text,
  network: IDL.Text,
  signature: IDL.Vec(IDL.Nat8),
  publicKey: IDL.Opt(IDL.Vec(IDL.Nat8)),
  sender: IDL.Text,
  nonce: IDL.Vec(IDL.Nat8),
  authorization: IDL.Opt(Eip3009Authorization),
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
  paymentRequired: IDL.Vec(PaymentRequirement),
  ok: ContentDelivery,
  error: IDL.Text,
});

const SearchResult = IDL.Variant({
  paymentRequired: IDL.Vec(PaymentRequirement),
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

// ── Identity (ERC-8004) ──

const ServiceEntry = IDL.Record({
  name: IDL.Text,
  endpoint: IDL.Text,
  version: IDL.Text,
  skills: IDL.Vec(IDL.Text),
  domains: IDL.Vec(IDL.Text),
});

const AgentCard = IDL.Record({
  name: IDL.Text,
  description: IDL.Text,
  services: IDL.Vec(ServiceEntry),
  x402Support: IDL.Bool,
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

// ── Remote Signer (sign-only mode) ──

const SignedTransaction = IDL.Record({
  rawTx: IDL.Text,
  txHash: IDL.Text,
});

const SignedAuthorizationFields = IDL.Record({
  from: IDL.Text,
  to: IDL.Text,
  value: IDL.Nat,
  validAfter: IDL.Nat,
  validBefore: IDL.Nat,
  nonce: IDL.Text,
  signature: IDL.Text,
});

const SignedAuthorization = IDL.Record({
  header: IDL.Text,
  paidAmount: IDL.Nat,
  authorization: SignedAuthorizationFields,
});

const SignedTxResult = IDL.Variant({ ok: SignedTransaction, err: IDL.Text });
const SignedAuthResult = IDL.Variant({ ok: SignedAuthorization, err: IDL.Text });

const SignedTypedDataRecord = IDL.Record({
  signature: IDL.Text,
  signer: IDL.Text,
  digest: IDL.Text,
  v: IDL.Nat8,
  r: IDL.Text,
  s: IDL.Text,
});
const SignedTypedDataResult = IDL.Variant({ ok: SignedTypedDataRecord, err: IDL.Text });

// ── Service Marketplace ──

const ServiceType = IDL.Variant({ Sync: IDL.Null, Async: IDL.Null });
const PricingScheme = IDL.Variant({ Exact: IDL.Nat, Upto: IDL.Nat, Session: IDL.Null });
const VerificationMethod = IDL.Variant({
  ZkGroth16: IDL.Record({ verificationKey: IDL.Vec(IDL.Nat8), verifierCanister: IDL.Principal }),
  HashMatch: IDL.Null,
  BuyerConfirm: IDL.Record({ disputeWindowSeconds: IDL.Nat }),
  AutoSettle: IDL.Null,
});
const ServiceDeliveryMethod = IDL.Variant({ Poll: IDL.Null, Callback: IDL.Null, Both: IDL.Null });

const ServiceDef = IDL.Record({
  id: IDL.Text,
  name: IDL.Text,
  description: IDL.Text,
  serviceType: ServiceType,
  pricing: PricingScheme,
  verification: VerificationMethod,
  delivery: ServiceDeliveryMethod,
  timeout: IDL.Nat,
  operatorId: IDL.Principal,
  enabled: IDL.Bool,
  createdAt: IDL.Int,
});

const JobStatusVariant = IDL.Variant({
  Pending: IDL.Null,
  Assigned: IDL.Null,
  Computing: IDL.Null,
  Submitted: IDL.Null,
  Verified: IDL.Null,
  Settled: IDL.Null,
  Disputed: IDL.Null,
  Expired: IDL.Null,
  Refunded: IDL.Null,
});

const JobRecord = IDL.Record({
  id: IDL.Text,
  serviceId: IDL.Text,
  buyer: IDL.Text,
  operator: IDL.Opt(IDL.Principal),
  params: IDL.Vec(IDL.Nat8),
  paymentReceiptId: IDL.Text,
  amount: IDL.Nat,
  actualCost: IDL.Opt(IDL.Nat),
  status: JobStatusVariant,
  result: IDL.Opt(IDL.Vec(IDL.Nat8)),
  proof: IDL.Opt(IDL.Vec(IDL.Nat8)),
  createdAt: IDL.Int,
  expiresAt: IDL.Int,
  completedAt: IDL.Opt(IDL.Int),
  deliveryCallback: IDL.Opt(IDL.Text),
});

export const exampleIdlFactory = () =>
  IDL.Service({
    // Paid service
    search: IDL.Func([IDL.Text, IDL.Opt(PaymentSignature)], [SearchResult], []),
    // Sessions
    requestSession: IDL.Func([], [SessionIntent], []),
    openSession: IDL.Func([SessionConfig, PaymentSignature], [OpenSessionResult], []),
    sessionQuery: IDL.Func([Voucher, IDL.Text], [SessionQueryResult], []),
    endSession: IDL.Func([IDL.Text], [PaymentResult], []),
    // Pattern 1: In-canister content (ContentStore)
    uploadContent: IDL.Func([IDL.Text, IDL.Text, IDL.Vec(IDL.Nat8)], [ContentStoreResult], []),
    uploadContentInit: IDL.Func([IDL.Text, IDL.Text, IDL.Nat, IDL.Nat], [ContentStoreResult], []),
    uploadContentChunk: IDL.Func([IDL.Text, IDL.Nat, IDL.Vec(IDL.Nat8)], [ContentStoreResult], []),
    deleteContent: IDL.Func([IDL.Text], [ContentStoreResult], []),
    listContent: IDL.Func([], [IDL.Vec(ContentEntry)], ['query']),
    getContent: IDL.Func([IDL.Text, IDL.Opt(PaymentSignature)], [GetContentResult], []),
    getChunk: IDL.Func([AccessGrant, IDL.Nat], [IDL.Opt(IDL.Vec(IDL.Nat8))], ['query']),
    // Pattern 2: Asset canister
    getAssetContent: IDL.Func([IDL.Text, IDL.Opt(PaymentSignature)], [GetContentResult], []),
    // Pattern 3: External (S3/IPFS/Arweave)
    getExternalContent: IDL.Func([IDL.Text, IDL.Opt(PaymentSignature)], [GetContentResult], []),
    // Identity (ERC-8004)
    getAgentCard: IDL.Func([], [AgentCard], ['query']),
    getAgentId: IDL.Func([], [IDL.Opt(IDL.Nat)], ['query']),
    getEvmPublicKey: IDL.Func([], [IDL.Vec(IDL.Nat8)], []),
    getEvmAddress: IDL.Func([], [IDL.Text], []),
    // Admin
    verifyGrant: IDL.Func([AccessGrant], [AccessGrantResult], ['query']),
    setPolicy: IDL.Func([SpendingPolicy], [], []),
    forceCloseSession: IDL.Func([IDL.Text], [PaymentResult], []),
    // Remote signer: sign-only endpoints (client broadcasts)
    signX402Payment: IDL.Func(
      [IDL.Nat, IDL.Text, IDL.Text, IDL.Nat, IDL.Text, IDL.Text],
      [SignedAuthResult],
      [],
    ),
    signErc20Transfer: IDL.Func(
      [IDL.Nat, IDL.Text, IDL.Text, IDL.Nat, IDL.Nat, IDL.Nat, IDL.Nat],
      [SignedTxResult],
      [],
    ),
    signEthTransfer: IDL.Func(
      [IDL.Nat, IDL.Text, IDL.Nat, IDL.Nat, IDL.Nat, IDL.Nat, IDL.Nat],
      [SignedTxResult],
      [],
    ),
    signAgentRegistration: IDL.Func([IDL.Nat, IDL.Nat, IDL.Nat], [SignedTxResult], []),
    // EIP-712 generic signing
    signTypedData: IDL.Func([IDL.Vec(IDL.Nat8), IDL.Vec(IDL.Nat8)], [SignedTypedDataResult], []),
    keccak256: IDL.Func([IDL.Vec(IDL.Nat8)], [IDL.Vec(IDL.Nat8)], ['query']),
    // Service marketplace
    registerService: IDL.Func(
      [
        IDL.Text,
        IDL.Text,
        ServiceType,
        PricingScheme,
        IDL.Text,
        IDL.Opt(IDL.Text),
        IDL.Opt(IDL.Vec(IDL.Nat8)),
        ServiceDeliveryMethod,
        IDL.Nat,
      ],
      [IDL.Variant({ ok: IDL.Text, err: IDL.Text })],
      [],
    ),
    enableService: IDL.Func([IDL.Text], [IDL.Variant({ ok: IDL.Null, err: IDL.Text })], []),
    disableService: IDL.Func([IDL.Text], [IDL.Variant({ ok: IDL.Null, err: IDL.Text })], []),
    listServices: IDL.Func([], [IDL.Vec(ServiceDef)], ['query']),
    submitServiceRequest: IDL.Func(
      [IDL.Text, IDL.Vec(IDL.Nat8), IDL.Opt(PaymentSignature)],
      [
        IDL.Variant({
          paymentRequired: IDL.Vec(PaymentRequirement),
          ok: IDL.Record({ jobId: IDL.Text }),
          error: IDL.Text,
        }),
      ],
      [],
    ),
    claimJob: IDL.Func([IDL.Text], [IDL.Variant({ ok: IDL.Null, err: IDL.Text })], []),
    submitJobResult: IDL.Func(
      [IDL.Text, IDL.Vec(IDL.Nat8), IDL.Opt(IDL.Vec(IDL.Nat8)), IDL.Opt(IDL.Nat)],
      [IDL.Variant({ ok: IDL.Null, err: IDL.Text })],
      [],
    ),
    confirmJob: IDL.Func([IDL.Text], [IDL.Variant({ ok: IDL.Null, err: IDL.Text })], []),
    disputeJob: IDL.Func([IDL.Text, IDL.Text], [IDL.Variant({ ok: IDL.Null, err: IDL.Text })], []),
    getJobStatus: IDL.Func([IDL.Text], [IDL.Opt(JobStatusVariant)], ['query']),
    getJob: IDL.Func([IDL.Text], [IDL.Opt(JobRecord)], ['query']),
    getJobResult: IDL.Func([IDL.Text], [IDL.Opt(IDL.Vec(IDL.Nat8))], ['query']),
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
  ServiceEntry,
  AgentCard,
  SignedTransaction,
  SignedAuthorization,
  SignedTxResult,
  SignedAuthResult,
};
