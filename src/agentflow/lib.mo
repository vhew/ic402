/// agentflow — Drop-in payment library for ICP canisters.
///
/// ```motoko
/// import Agentflow "mo:agentflow";
/// let gate = Agentflow.Gateway({ ... });
/// ```

import Types "Types";
import Gateway "Gateway";
import Policy "Policy";

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

  // Re-export gateway
  public let Gateway = Gateway.Gateway;
};
