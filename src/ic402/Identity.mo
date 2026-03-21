/// ic402 — Optional agent identity module (ERC-8004).
///
/// Manages agent cards for discovery and ERC-8004 on-chain registration.
/// Import only if your canister needs to be discoverable as an agent.
///
/// ```motoko
/// transient let id = Ic402.Identity({
///   chain = #base;
///   card = { name = "MyAgent"; description = "..."; services = []; x402Support = true };
/// });
/// ```
import Types "Types";

module {

  /// Agent identity with ERC-8004 registration support.
  public class Identity(config : Types.ERC8004Config) {

    var agentId : ?Nat = null;

    /// Get the agent card metadata.
    public func getCard() : Types.AgentCard {
      config.card;
    };

    /// Get the chain this identity targets.
    public func getChain() : { #avalanche; #base; #ethereum; #polygon } {
      config.chain;
    };

    /// Get the registered agent ID, if any.
    public func getAgentId() : ?Nat {
      agentId;
    };

    /// Register as an agent on ERC-8004 (stub — tECDSA post-hackathon).
    /// Mints an ERC-721 on the IdentityRegistry contract.
    public func registerAgent() : async Nat {
      // TODO: tECDSA sign EVM transaction to mint ERC-721 on IdentityRegistry
      let id = 0; // Placeholder agent ID
      agentId := ?id;
      id;
    };

    /// Serialize for canister upgrades.
    public func toStable() : Types.StableIdentityState {
      { agentId };
    };

    /// Deserialize after upgrade.
    public func loadStable(data : Types.StableIdentityState) {
      agentId := data.agentId;
    };
  };
};
