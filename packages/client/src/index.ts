export { Ic402Client } from './client.js';
export type {
  Ic402Identity,
  Ic402ClientConfig,
  SessionHandle,
  SessionPreferences,
} from './client.js';
export type {
  PaymentRequirement,
  PaymentReceipt,
  SessionIntent,
  SessionState,
  Voucher,
  ContentRef,
  AccessGrant,
  AccessGrantResult,
  DeliveryMethod,
  ContentDelivery,
  ContentEntry,
  ContentStoreResult,
} from './types.js';
export type {
  Eip3009Authorization,
  X402PaymentRequirement,
  SignedTransaction,
  SignedAuthorization,
  SignedTypedData,
  ServiceType,
  PricingScheme,
  VerificationMethod,
  ServiceDeliveryMethod,
  ServiceDefinition,
  JobStatus,
  Job,
} from './types.js';
export { signVoucher, encodeVoucherPayload } from './voucher.js';
export type { VoucherSigner } from './voucher.js';
export { exampleIdlFactory } from './idl.js';
// Wire-form (agent-js Candid encoding) types for hand-built canister-argument payloads —
// annotate a raw PaymentSignature/authorization so `tsc` flags a missing field (e.g. `asset`).
export type { PaymentSignatureArg, Eip3009AuthorizationArg } from './idl.js';
export {
  usdcDomain,
  TRANSFER_WITH_AUTHORIZATION_TYPES,
  buildTransferAuthorizationMessage,
} from './eip712.js';
export {
  Ic402Error,
  classifyNetworkError,
  findPaymentOption,
  applyVerbatimAccepted,
  probeX402,
  fetchX402,
  createEvmClient,
  getEvmNonce,
  getFeeData,
  broadcastTransaction,
  pollReceipt,
  parseAgentRegisteredEvent,
  registerAgent,
} from './evm.js';
export type { Ic402ErrorKind, PaymentOption, FetchX402Result, ProbeResult } from './evm.js';
