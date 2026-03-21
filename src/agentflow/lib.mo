/// agentflow — Drop-in payment library for ICP canisters.
///
/// ```motoko
/// import Agentflow "mo:agentflow";
/// let gate = Agentflow.Gateway({ ... }, Principal.fromActor(self));
/// ```

import Types "Types";
import GatewayModule "Gateway";
import NonceMod "Nonce";
import EscrowMod "Escrow";

module {

  // Re-export types
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
  public type ERC8004Config = Types.ERC8004Config;
  public type AgentCard = Types.AgentCard;
  public type ServiceEntry = Types.ServiceEntry;
  public type AvaxConfig = Types.AvaxConfig;
  public type AvaxTokenConfig = Types.AvaxTokenConfig;
  public type StableGatewayState = Types.StableGatewayState;
  public type Account = Types.Account;
  public type TransferResult = Types.TransferResult;

  // Re-export classes
  public let Gateway = GatewayModule.Gateway;
  public let NonceManager = NonceMod.NonceManager;
  public let EscrowManager = EscrowMod.EscrowManager;
};
