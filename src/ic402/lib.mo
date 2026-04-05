/// ic402 — Drop-in payment library for ICP canisters.
///
/// - **Inbound**: `Gateway` handles payment settlement (ICP via ICRC-2,
///   EVM via EvmSender internally).
/// - **Outbound**: `EvmSigner` signs EVM transactions; the client broadcasts.
/// - **Content**: `ContentStore` provides encrypted storage and delivery.
/// - **Identity**: `Identity` holds ERC-8004 agent metadata and derives
///   the canister's EVM key pair via threshold ECDSA.
///
/// ```motoko
/// import Ic402 "mo:ic402";
/// let gate = Ic402.Gateway({ ... }, Principal.fromActor(self));
/// ```

import Types "Types";
import GatewayModule "Gateway";
import ContentStoreMod "ContentStore";
import IdentityMod "Identity";
import HttpHandlerMod "HttpHandler";
import IC "mo:ic";
import EvmSignerMod "EvmSigner";
import Eip712Mod "Eip712";
import EvmAddressMod "EvmAddress";
import EvmUtilsMod "EvmUtils";
import ServiceRegistryMod "ServiceRegistry";

module {

  // ── Core types ──

  /// Top-level gateway configuration.
  public type Config = Types.Config;
  /// Token ledger configuration (principal, symbol, decimals).
  public type TokenConfig = Types.TokenConfig;
  /// Payment price: token, amount, and CAIP-2 network.
  public type Price = Types.Price;
  /// 402 payment requirement returned to clients.
  public type PaymentRequirement = Types.PaymentRequirement;
  /// Client-supplied payment proof.
  public type PaymentSignature = Types.PaymentSignature;
  /// On-chain settlement receipt.
  public type PaymentReceipt = Types.PaymentReceipt;
  /// Outcome of a payment settlement attempt.
  public type PaymentResult = Types.PaymentResult;
  /// Session offer describing deposit, cost, and expiry.
  public type SessionIntent = Types.SessionIntent;
  /// Client-side session preferences.
  public type SessionConfig = Types.SessionConfig;
  /// Public view of a session's state.
  public type SessionState = Types.SessionState;
  /// Session lifecycle status.
  public type SessionStatus = Types.SessionStatus;
  /// Cumulative payment voucher signed by the session payer.
  public type Voucher = Types.Voucher;
  /// Outcome of voucher consumption.
  public type VoucherResult = Types.VoucherResult;
  /// Spending limits and access control policy.
  public type SpendingPolicy = Types.SpendingPolicy;
  /// EVM chain configuration.
  public type EvmChainConfig = Types.EvmChainConfig;
  /// EVM ERC-20 token configuration.
  public type EvmTokenConfig = Types.EvmTokenConfig;
  /// EIP-3009 TransferWithAuthorization parameters.
  public type Eip3009Authorization = Types.Eip3009Authorization;
  /// ICRC-1 account (owner + optional subaccount).
  public type Account = Types.Account;
  /// ICRC-1 transfer result.
  public type TransferResult = Types.TransferResult;

  // ── Stable state (required for preupgrade/postupgrade) ──

  /// Serializable gateway state for canister upgrades.
  public type StableGatewayState = Types.StableGatewayState;
  /// Serializable content store state for canister upgrades.
  public type StableContentStoreState = Types.StableContentStoreState;
  /// Serializable identity state for canister upgrades.
  public type StableIdentityState = Types.StableIdentityState;

  // ── Content delivery ──

  /// Reference to stored content.
  public type ContentRef = Types.ContentRef;
  /// HMAC-signed access grant for content delivery.
  public type AccessGrant = Types.AccessGrant;
  /// Result of access grant verification.
  public type AccessGrantResult = Types.AccessGrantResult;
  /// How content is delivered (inline, HTTP, query, asset canister).
  public type DeliveryMethod = Types.DeliveryMethod;
  /// Access grant paired with its delivery method.
  public type ContentDelivery = Types.ContentDelivery;
  /// Metadata for a stored content item.
  public type ContentEntry = Types.ContentEntry;
  /// Result of content store operations.
  public type ContentStoreResult = Types.ContentStoreResult;

  // ── Identity (ERC-8004) ──

  /// ERC-8004 agent identity configuration.
  public type ERC8004Config = Types.ERC8004Config;
  /// Gas fee overrides for EVM transactions.
  public type GasConfig = Types.GasConfig;
  /// Result of ERC-8004 agent registration.
  public type RegisterAgentResult = Types.RegisterAgentResult;
  /// ERC-8004 agent metadata.
  public type AgentCard = Types.AgentCard;
  /// Service endpoint in an agent card.
  public type ServiceEntry = Types.ServiceEntry;

  // ── EVM Signer (sign-only mode) ──

  /// Signed EVM transaction ready for client-side broadcast.
  public type SignedTransaction = EvmSignerMod.SignedTransaction;
  /// Signed EIP-3009 authorization for x402 payment headers.
  public type SignedAuthorization = EvmSignerMod.SignedAuthorization;
  /// Signed EIP-712 typed data (generic — works for any EIP-712 protocol).
  public type SignedTypedData = EvmSignerMod.SignedTypedData;

  // ── HTTP ──

  /// IC HTTP gateway request.
  public type HttpRequest = Types.HttpRequest;
  /// IC HTTP gateway response.
  public type HttpResponse = Types.HttpResponse;
  /// IC HTTPS outcall response (for transform functions).
  public type HttpResponse_ = IC.HttpRequestResult;
  /// HTTP response builder and payment header parser.
  public let HttpHandler = HttpHandlerMod;

  // ── Classes ──

  /// Main payment gateway: charges, sessions, grants, escrow, and policy.
  public let Gateway = GatewayModule.Gateway;
  /// Encrypted content store with chunked upload.
  public let ContentStore = ContentStoreMod.ContentStore;
  /// ERC-8004 agent identity: metadata and key derivation.
  public let Identity = IdentityMod.Identity;
  /// EIP-712 typed data hashing utilities (domain separators, struct hashes, digest).
  public let Eip712 = Eip712Mod;
  /// EVM address derivation and keccak256 hashing.
  public let EvmAddress = EvmAddressMod;
  /// EVM ABI encoding, hex conversion, and byte utilities.
  public let EvmUtils = EvmUtilsMod;
  /// EVM remote signer: canister signs, client broadcasts.
  public let EvmSigner = EvmSignerMod;
  /// Service marketplace: register services, manage jobs, verify and settle.
  public let ServiceRegistry = ServiceRegistryMod.ServiceRegistry;

  // ── Service marketplace types ──

  public type ServiceType = Types.ServiceType;
  public type PricingScheme = Types.PricingScheme;
  public type VerificationMethod = Types.VerificationMethod;
  public type ServiceDeliveryMethod = Types.ServiceDeliveryMethod;
  public type ServiceDefinition = Types.ServiceDefinition;
  public type JobStatus = Types.JobStatus;
  public type Job = Types.Job;
  public type ServiceConfig = ServiceRegistryMod.ServiceConfig;
  public type StableServiceRegistryState = Types.StableServiceRegistryState;
  public type ZkVerifierActor = Types.ZkVerifierActor;
};
