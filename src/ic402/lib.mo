/// ic402 — Drop-in payment library for ICP canisters.
///
/// ```motoko
/// import Ic402 "mo:ic402";
/// let gate = Ic402.Gateway({ ... }, Principal.fromActor(self));
/// ```

import Types "Types";
import GatewayModule "Gateway";
import GrantsMod "Grants";
import SessionsMod "Sessions";
import NonceMod "Nonce";
import EscrowMod "Escrow";
import ContentStoreMod "ContentStore";
import IdentityMod "Identity";
import HttpHandlerMod "HttpHandler";
import EvmAddressMod "EvmAddress";
import IC "mo:ic";
import EvmUtilsMod "EvmUtils";
import EvmRpcMod "EvmRpc";
import EvmEscrowMod "EvmEscrow";
import EvmSenderMod "EvmSender";
import Eip712Mod "Eip712";
import X402ClientMod "X402Client";

module {

  // ── Core types ──

  public type Config = Types.Config;
  public type TokenConfig = Types.TokenConfig;
  public type Price = Types.Price;
  public type PaymentRequirement = Types.PaymentRequirement;
  public type PaymentSignature = Types.PaymentSignature;
  public type PaymentReceipt = Types.PaymentReceipt;
  public type PaymentResult = Types.PaymentResult;
  public type SessionIntent = Types.SessionIntent;
  public type SessionConfig = Types.SessionConfig;
  public type SessionState = Types.SessionState;
  public type SessionStatus = Types.SessionStatus;
  public type Voucher = Types.Voucher;
  public type VoucherResult = Types.VoucherResult;
  public type SpendingPolicy = Types.SpendingPolicy;
  public type TrustRequirements = Types.TrustRequirements;
  public type EvmChainConfig = Types.EvmChainConfig;
  public type EvmTokenConfig = Types.EvmTokenConfig;
  public type StableGatewayState = Types.StableGatewayState;
  public type Account = Types.Account;
  public type TransferResult = Types.TransferResult;
  public type ContentRef = Types.ContentRef;
  public type AccessGrant = Types.AccessGrant;
  public type AccessGrantResult = Types.AccessGrantResult;
  public type DeliveryMethod = Types.DeliveryMethod;
  public type ContentDelivery = Types.ContentDelivery;

  // ── Content Store (optional) ──

  public type ContentEntry = Types.ContentEntry;
  public type ContentStoreResult = Types.ContentStoreResult;
  public type StableContentStoreState = Types.StableContentStoreState;
  public type StableContentEntry = Types.StableContentEntry;

  // ── Identity (optional) ──

  public type ERC8004Config = Types.ERC8004Config;
  public type GasConfig = Types.GasConfig;
  public type RegisterAgentResult = Types.RegisterAgentResult;
  public type AgentCard = Types.AgentCard;
  public type ServiceEntry = Types.ServiceEntry;
  public type StableIdentityState = Types.StableIdentityState;

  // ── HTTP ──

  public type HttpRequest = Types.HttpRequest;
  public type HttpResponse = Types.HttpResponse;
  public let HttpHandler = HttpHandlerMod;

  // ── Classes ──

  public let Gateway = GatewayModule.Gateway;
  public let Grants = GrantsMod.Grants;
  public let Sessions = SessionsMod.Sessions;
  public let NonceManager = NonceMod.NonceManager;
  public let EscrowManager = EscrowMod.EscrowManager;
  public let ContentStore = ContentStoreMod.ContentStore;
  public let Identity = IdentityMod.Identity;
  public let EvmAddress = EvmAddressMod;
  public let EvmUtils = EvmUtilsMod;
  public let EvmRpc = EvmRpcMod;
  public let EvmEscrow = EvmEscrowMod;
  public let EvmSender = EvmSenderMod;
  public let Eip712 = Eip712Mod;
  public let X402Client = X402ClientMod;

  // ── New types (x402 standard) ──
  public type Eip3009Authorization = Types.Eip3009Authorization;
  public type HttpResponse_ = IC.HttpRequestResult; // IC HTTPS outcall response (for transform functions)
};
