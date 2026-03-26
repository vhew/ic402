/// ic402 — Agent identity module with on-canister EVM transaction signing.
///
/// Manages agent cards for discovery and registers the canister on
/// ERC-8004's IdentityRegistry contract on Base (or other EVM chains).
/// The canister signs the EVM transaction itself using ICP's threshold ECDSA.
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
import EvmUtils "EvmUtils";
import EvmRpc "EvmRpc";
import EvmAddress "EvmAddress";
import Blob "mo:base/Blob";
import Array "mo:base/Array";
import Nat "mo:base/Nat";
import Error "mo:base/Error";
import Result "mo:base/Result";
import IC "mo:ic";
import Call "mo:ic/Call";

module {

  /// Agent identity with ERC-8004 on-chain registration.
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
            case (#err(e)) { assert(false); "" }; // should never happen
          };
          evmAddress := ?addr;
          addr;
        };
      };
    };

    // ── Registration ──

    /// Register as an agent on the ERC-8004 IdentityRegistry contract.
    /// The canister signs and submits the EVM transaction autonomously.
    public func registerAgent() : async Types.RegisterAgentResult {
      switch (agentId) {
        case (?id) { return #ok({ tokenId = id; txHash = "" }) };
        case (null) {};
      };

      try {
        // 1. Get public key and EVM address
        let pubKeyBlob = await getPublicKey(config.ecdsaKeyName);
        let pubKey = Blob.toArray(pubKeyBlob);
        let addr = await getEvmAddress();

        // 2. Resolve EVM RPC
        let rpcPrincipal = switch (config.evmRpcCanister) {
          case (?p) { p };
          case (null) { EvmRpc.DEFAULT_CANISTER };
        };
        let evmRpc : EvmRpc.EvmRpcCanister = actor (rpcPrincipal);
        let services = switch (EvmRpc.rpcServices(config.chainId)) {
          case (?s) { s };
          case (null) { return #err("Unsupported chain ID: " # Nat.toText(config.chainId)) };
        };

        // 3. Get EVM nonce
        let evmNonce = await getEvmNonce(evmRpc, services, addr);

        // 4. Get fee data
        let (maxFee, priorityFee) = await getFeeData(evmRpc, services);

        // 5. Build calldata
        let calldata = buildRegisterCalldata();

        // 6. Determine gas limit
        let gasLimit = switch (config.gasConfig) {
          case (?gc) {
            switch (gc.gasLimit) { case (?g) { g }; case (null) { 350_000 } };
          };
          case (null) { 350_000 };
        };

        // 7. Build unsigned tx
        let txParams : EvmUtils.TxParams = {
          chainId = config.chainId;
          nonce = evmNonce;
          maxPriorityFeePerGas = priorityFee;
          maxFeePerGas = maxFee;
          gasLimit;
          to = EvmUtils.addressToBytes(config.registryAddress);
          value = 0;
          data = calldata;
        };
        let txHash = EvmUtils.unsignedTxHash(txParams);

        // 8. Sign via tECDSA
        let signResult = await Call.signWithEcdsa({
          key_id = { name = config.ecdsaKeyName; curve = #secp256k1 };
          derivation_path = [];
          message_hash = Blob.fromArray(txHash);
        });
        let sigBytes = Blob.toArray(signResult.signature);
        let r = Array.subArray(sigBytes, 0, 32);
        let s = Array.subArray(sigBytes, 32, 32);

        // 9. Determine yParity
        let yParity = EvmAddress.recoverYParity(txHash, r, s, pubKey);

        // 10. Build signed raw tx
        let rawTxBytes = EvmUtils.signedRawTx(txParams, r, s, yParity);
        let rawTxHex = EvmUtils.bytesToHex(rawTxBytes);

        // 11. Submit
        let sendResult = await (with cycles = EvmRpc.RPC_CYCLES) evmRpc.eth_sendRawTransaction(services, null, rawTxHex);
        let sendTxHash = switch (sendResult) {
          case (#Consistent(#Ok(#Ok(?hash)))) { hash };
          case (#Consistent(#Ok(#Ok(null)))) { rawTxHex }; // some providers don't return hash
          case (#Consistent(#Ok(#NonceTooLow))) { return #err("Nonce too low — canister may have pending tx") };
          case (#Consistent(#Ok(#NonceTooHigh))) { return #err("Nonce too high") };
          case (#Consistent(#Ok(#InsufficientFunds))) { return #err("Insufficient ETH for gas at " # addr) };
          case (#Consistent(#Err(e))) { return #err("RPC error: " # EvmRpc.rpcErrorToText(e)) };
          case (#Inconsistent(_)) { return #err("Inconsistent RPC responses on sendRawTransaction") };
        };

        // 12. Poll for receipt (3 attempts, each inter-canister call ~2-4s implicit delay)
        var receipt : ?EvmRpc.TransactionReceipt = null;
        var attempt = 0;
        while (attempt < 5 and receipt == null) {
          let recResult = await (with cycles = EvmRpc.RPC_CYCLES) evmRpc.eth_getTransactionReceipt(services, null, sendTxHash);
          switch (recResult) {
            case (#Consistent(#Ok(?r))) { receipt := ?r };
            case (_) {};
          };
          attempt += 1;
        };

        // 13. Parse AgentRegistered event
        switch (receipt) {
          case (?r) {
            let tokenId = parseAgentRegisteredEvent(r.logs);
            switch (tokenId) {
              case (?id) {
                agentId := ?id;
                #ok({ tokenId = id; txHash = sendTxHash });
              };
              case (null) {
                // Tx confirmed but no event found — might still be registering
                #ok({ tokenId = 0; txHash = sendTxHash });
              };
            };
          };
          case (null) {
            // Tx submitted but not yet confirmed
            #err("Tx submitted (" # sendTxHash # ") but not yet confirmed. Call getAgentId() later to check.");
          };
        };
      } catch (e) {
        #err("Registration failed: " # Error.message(e));
      };
    };

    // ── Internal helpers ──

    func buildRegisterCalldata() : [Nat8] {
      let service = if (config.card.services.size() > 0) {
        config.card.services[0];
      } else {
        { name = ""; endpoint = ""; version = ""; skills = []; domains = [] };
      };

      let selector = EvmUtils.functionSelector("register(string,string,string,string[],string[],bool)");
      EvmUtils.abiEncodeFunctionCall(
        selector,
        [
          #dynamic(EvmUtils.abiEncodeString(config.card.name)),
          #dynamic(EvmUtils.abiEncodeString(config.card.description)),
          #dynamic(EvmUtils.abiEncodeString(service.endpoint)),
          #dynamic(EvmUtils.abiEncodeStringArray(service.skills)),
          #dynamic(EvmUtils.abiEncodeStringArray(service.domains)),
          #static_(EvmUtils.abiEncodeBool(config.card.x402Support)),
        ],
      );
    };

    func getEvmNonce(evmRpc : EvmRpc.EvmRpcCanister, services : EvmRpc.RpcServices, address : Text) : async Nat {
      let result = await (with cycles = EvmRpc.RPC_CYCLES) evmRpc.eth_getTransactionCount(
        services, null,
        { address; block = #Latest },
      );
      switch (result) {
        case (#Consistent(#Ok(n))) { n };
        case (#Consistent(#Err(e))) { throw Error.reject("Failed to get nonce: " # EvmRpc.rpcErrorToText(e)) };
        case (#Inconsistent(_)) { throw Error.reject("Inconsistent nonce responses") };
      };
    };

    func getFeeData(evmRpc : EvmRpc.EvmRpcCanister, services : EvmRpc.RpcServices) : async (Nat, Nat) {
      // Check for config overrides first
      let cfgMax = switch (config.gasConfig) {
        case (?gc) { gc.maxFeePerGas };
        case (null) { null };
      };
      let cfgPriority = switch (config.gasConfig) {
        case (?gc) { gc.maxPriorityFeePerGas };
        case (null) { null };
      };
      switch (cfgMax, cfgPriority) {
        case (?m, ?p) { return (m, p) };
        case (_, _) {};
      };

      // Query fee history for baseFeePerGas
      try {
        let result = await (with cycles = EvmRpc.RPC_CYCLES) evmRpc.eth_feeHistory(
          services, null,
          { blockCount = 1; newestBlock = #Latest; rewardPercentiles = null },
        );
        switch (result) {
          case (#Consistent(#Ok(history))) {
            let baseFee = if (history.baseFeePerGas.size() > 1) {
              history.baseFeePerGas[1]; // next block's base fee
            } else if (history.baseFeePerGas.size() > 0) {
              history.baseFeePerGas[0];
            } else {
              1_000_000_000; // 1 gwei fallback
            };
            // Priority fee: use config override, or scale to base fee
            // On L2s (Base, Optimism) base fee can be < 0.01 gwei;
            // on Ethereum mainnet it's 1-50 gwei. Scale accordingly.
            let priorityFee = switch (cfgPriority) {
              case (?p) { p };
              case (null) {
                // Reasonable default: at least baseFee, capped at 1.5 gwei
                let minPriority = 1_000_000; // 0.001 gwei floor
                if (baseFee > 1_500_000_000) { 1_500_000_000 } // Ethereum mainnet
                else if (baseFee > minPriority) { baseFee }     // proportional to base
                else { minPriority };                            // L2 floor
              };
            };
            let maxFee = switch (cfgMax) {
              case (?m) { m };
              case (null) { 2 * baseFee + priorityFee };
            };
            (maxFee, priorityFee);
          };
          case (_) {
            // Fallback: conservative defaults (works on both L1 and L2)
            (100_000_000, 10_000_000); // 0.1 gwei max, 0.01 gwei priority
          };
        };
      } catch (_) {
        (100_000_000, 10_000_000);
      };
    };

    /// Parse AgentRegistered event from transaction logs.
    /// event AgentRegistered(uint256 indexed tokenId, address indexed owner, ...)
    func parseAgentRegisteredEvent(logs : [EvmRpc.LogEntry]) : ?Nat {
      let eventSig = EvmAddress.toHex(EvmAddress.keccak256Text("AgentRegistered(uint256,address,string,string,bool)"));
      for (log in logs.vals()) {
        if (log.topics.size() >= 2) {
          if (log.topics[0] == eventSig) {
            // topics[1] is the indexed tokenId (uint256, zero-padded hex)
            return ?EvmUtils.bytesToNat(EvmUtils.hexToBytes(log.topics[1]));
          };
        };
      };
      null;
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
