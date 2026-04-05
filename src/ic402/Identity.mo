/// ic402 — Agent identity metadata and key derivation.
///
/// Holds ERC-8004 agent card data and derives the canister's EVM address
/// via ICP threshold ECDSA. On-chain registration is handled externally
/// through EvmSigner (canister signs) and the client (broadcasts).
///
/// ```motoko
/// transient let id = Ic402.Identity({
///   chain = #base;
///   card = { name = "MyAgent"; ... };
///   ecdsaKeyName = "dfx_test_key";
///   registryAddress = "0x140D228d...";
///   chainId = 84532;
///   evmRpcCanister = null;
///   gasConfig = null;
/// });
/// ```
import Types "Types";
import EvmAddress "EvmAddress";
import Blob "mo:base/Blob";
import Debug "mo:base/Debug";
import IC "mo:ic";

module {

  /// ERC-8004 agent identity: card metadata and key derivation.
  public class Identity(config : Types.ERC8004Config) {

    var agentId : ?Nat = null;
    var evmAddress : ?Text = null;
    var cachedPubKey : ?[Nat8] = null;

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

    /// Set the registered agent ID (admin fallback for external registration).
    public func setAgentId(id : Nat) {
      agentId := ?id;
    };

    /// Get the canister's secp256k1 public key (SEC1 compressed, 33 bytes).
    public func getPublicKey(keyName : Text) : async Blob {
      switch (cachedPubKey) {
        case (?pk) { Blob.fromArray(pk) };
        case (null) {
          let result = await IC.ic.ecdsa_public_key({
            key_id = { name = keyName; curve = #secp256k1 };
            canister_id = null;
            derivation_path = [];
          });
          cachedPubKey := ?Blob.toArray(result.public_key);
          result.public_key;
        };
      };
    };

    /// Get or derive the canister's EVM address.
    public func getEvmAddress() : async Text {
      switch (evmAddress) {
        case (?addr) { addr };
        case (null) {
          let pk = await getPublicKey(config.ecdsaKeyName);
          let addr = switch (EvmAddress.fromCompressedPublicKey(Blob.toArray(pk))) {
            case (#ok(a)) { a };
            case (#err(_)) { Debug.trap("ic402: EVM address derivation failed") };
          };
          evmAddress := ?addr;
          addr;
        };
      };
    };

    /// Serialize for canister upgrades.
    public func toStable() : Types.StableIdentityState {
      { agentId; evmAddress };
    };

    /// Deserialize after upgrade.
    public func loadStable(data : Types.StableIdentityState) {
      agentId := data.agentId;
      switch (data.evmAddress) {
        case (?addr) { evmAddress := ?addr };
        case (null) {};
      };
    };
  };
};
