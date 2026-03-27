/// ic402 — Drop-in payment library for ICP canisters.
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
import X402ClientMod "X402Client";

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
  /// ERC-8004 agent identity registration.
  public let Identity = IdentityMod.Identity;
  /// x402 outbound payment client (HTTPS outcalls with auto-pay).
  public let X402Client = X402ClientMod;
};
