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
import ICTypes "mo:ic/Types";
import EvmSignerMod "EvmSigner";
import Eip712Mod "Eip712";
import EvmAddressMod "EvmAddress";
import EvmUtilsMod "EvmUtils";
import ServiceRegistryMod "ServiceRegistry";

module {

  /// Stable-state schema version for ic402's library `Stable*State` types. BUMP on any UPGRADE-
  /// BREAKING change to them: a removed or retyped field, OR a new field on an existing stable
  /// record — the last is breaking because consumers hold these snapshots in mutable `stable var`s,
  /// whose type is invariant across upgrade. Changes that stay upgrade-compatible do NOT need a bump:
  /// adding a new variant case, or a brand-new `?optional` stable variable. The CI gate
  /// (`scripts/check-stable-compat.sh`) is the authority — it decides with moc's own
  /// `--stable-compatible` oracle and FAILS the build on a breaking change that does not bump this.
  ///
  /// This is one coarse "any library stable type changed" signal (not per-component) — a consumer
  /// that persists only some components treats any bump as "consult the CHANGELOG for which
  /// components changed." Consumers persist this next to ic402's snapshots and check it BEFORE
  /// `loadStable` (see `checkSchemaVersion` + example/main.mo + docs/upgrade-safety.md), so a
  /// mismatch is a clear error or a migration branch — not a cryptic Candid trap on a live canister.
  public let STABLE_SCHEMA_VERSION : Nat = 1;

  /// Compare a consumer's PERSISTED schema version against this build's `STABLE_SCHEMA_VERSION`,
  /// to be called BEFORE `loadStable`. `#ok` → same version, decode directly. `#migrate` → persisted
  /// state is OLDER; run your migration for `from → to` before loading. `#ahead` → persisted state is
  /// from a NEWER ic402 than this build (a downgrade) — refuse. See example/main.mo for the wiring.
  public func checkSchemaVersion(persisted : Nat) : {
    #ok;
    #migrate : { from : Nat; to : Nat };
    #ahead : { persisted : Nat; current : Nat };
  } {
    if (persisted == STABLE_SCHEMA_VERSION) { #ok } else if (persisted < STABLE_SCHEMA_VERSION) {
      #migrate({ from = persisted; to = STABLE_SCHEMA_VERSION });
    } else { #ahead({ persisted; current = STABLE_SCHEMA_VERSION }) };
  };

  // ── Core types ──

  /// Top-level gateway configuration.
  public type Config = Types.Config;
  /// Token ledger configuration (principal, symbol, decimals).
  public type TokenConfig = Types.TokenConfig;
  /// Payment price: token, amount, and CAIP-2 network.
  public type Price = Types.Price;
  /// 402 payment requirement returned to clients.
  public type PaymentRequirement = Types.PaymentRequirement;
  /// Client-supplied payment proof. Field conventions differ for charges vs sessions, and
  /// `asset = null` falls back to the chain's first configured token — see Types.PaymentSignature.
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
  /// ic@4.0.0 moved canister types from the top-level module to `mo:ic/Types`.
  public type HttpResponse_ = ICTypes.HttpRequestResult;
  /// HTTP response builder and payment header parser.
  public let HttpHandler = HttpHandlerMod;

  // ── Classes ──

  /// Main payment gateway: charges, sessions, grants, escrow, and policy.
  public let Gateway = GatewayModule.Gateway;
  /// Encrypted content store with chunked upload.
  public let ContentStore = ContentStoreMod.ContentStore;
  /// ERC-8004 agent identity: metadata and key derivation.
  public let Identity = IdentityMod.Identity;
  /// IC self-authenticating principal for a raw 32-byte Ed25519 key (sha224(DER-SPKI)‖0x02);
  /// null if not 32 bytes. Ed25519-only and opportunistic — a mismatch means "not identity-bound",
  /// never "invalid" (II delegations / secp256k1 / P-256 derive different principals).
  public let selfAuthPrincipalOfEd25519 = IdentityMod.selfAuthPrincipalOfEd25519;
  /// caller-binding + possession in one check: the key derives `caller` AND `signature` verifies
  /// over `message` with it.
  public let verifyCallerEd25519 = IdentityMod.verifyCallerEd25519;
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

  /// Whether a service is fulfilled synchronously (inline) or asynchronously (job-queued).
  public type ServiceType = Types.ServiceType;
  /// How a buyer is charged: exact price, up-to authorization, or existing session deposit.
  public type PricingScheme = Types.PricingScheme;
  /// How a job result is verified (e.g. trust the operator, or a ZK Groth16 proof).
  public type VerificationMethod = Types.VerificationMethod;
  /// How a job result is delivered to the buyer: poll, callback, or both.
  public type ServiceDeliveryMethod = Types.ServiceDeliveryMethod;
  /// A registered service: id, name, pricing, verification, and delivery configuration.
  public type ServiceDefinition = Types.ServiceDefinition;
  /// Lifecycle state of a job (pending → assigned/computing → settled/refunded/expired).
  public type JobStatus = Types.JobStatus;
  /// A purchased unit of work against a service: buyer, payment rail, status, and result.
  public type Job = Types.Job;
  /// Construction config for the ServiceRegistry (payment recipient, tokens, ledger fee).
  public type ServiceConfig = ServiceRegistryMod.ServiceConfig;
  /// Serialized ServiceRegistry state (services + jobs + counters) for stable upgrade persistence.
  public type StableServiceRegistryState = Types.StableServiceRegistryState;
  /// Interface to an external ZK verifier canister (Groth16 proof verification).
  public type ZkVerifierActor = Types.ZkVerifierActor;
};
