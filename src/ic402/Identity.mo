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

  // Management canister for tECDSA
  let management_canister : actor {
    ecdsa_public_key : shared {
      key_id : { name : Text; curve : { #secp256k1 } };
      canister_id : ?Principal;
      derivation_path : [Blob];
    } -> async {
      public_key : Blob;
      chain_code : Blob;
    };
  } = actor "aaaaa-aa";

  /// Agent identity with ERC-8004 registration support.
  public class Identity(config : Types.ERC8004Config) {

    var agentId : ?Nat = null;

    /// Get the agent card metadata.
    public func getCard() : Types.AgentCard {
      config.card;
    };

    /// Get the chain this identity targets.
    public func getChain() : { #base; #ethereum; #avalanche; #optimism; #arbitrum } {
      config.chain;
    };

    /// Get the registered agent ID, if any.
    public func getAgentId() : ?Nat {
      agentId;
    };

    /// Get the canister's secp256k1 public key from ICP's threshold ECDSA service.
    /// Returns SEC1 compressed format (33 bytes).
    ///
    /// To derive the EVM address from this key:
    ///   1. Decompress to uncompressed format (65 bytes: 0x04 + X + Y)
    ///   2. Keccak-256 hash the 64 bytes after the 0x04 prefix
    ///   3. Take the last 20 bytes as the address
    ///
    /// keyName: "dfx_test_key" for local replica, "key_1" for mainnet IC.
    public func getPublicKey(keyName : Text) : async Blob {
      let result = await management_canister.ecdsa_public_key({
        key_id = { name = keyName; curve = #secp256k1 };
        canister_id = null;
        derivation_path = [];
      });
      result.public_key;
    };

    /// Set the registered agent ID (called by admin after external registration).
    public func setAgentId(id : Nat) {
      agentId := ?id;
    };

    /// Register as an agent on ERC-8004.
    /// Currently delegates to external registration script
    /// (scripts/register-agent.ts). Full on-canister EVM transaction
    /// signing (Keccak-256 + RLP + tECDSA) is a future milestone.
    public func registerAgent() : async Nat {
      switch (agentId) {
        case (?id) { id };
        case (null) { 0 };
      };
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
