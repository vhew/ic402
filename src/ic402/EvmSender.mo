// ic402 — EVM transaction sender via tECDSA.
///
// Signs and submits EVM transactions using the canister's threshold ECDSA key.
// Provides both generic transaction sending and ERC-20 transfer helpers.

import EvmUtils "EvmUtils";
import EvmRpc "EvmRpc";
import EvmAddress "EvmAddress";
import Blob "mo:base/Blob";
import Array "mo:base/Array";
import Nat "mo:base/Nat";
import Nat8 "mo:base/Nat8";
import Error "mo:base/Error";
import IC "mo:ic";
import Call "mo:ic/Call";

module {

  // EVM transaction sender with tECDSA signing.
  public class EvmSender(ecdsaKeyName : Text, evmRpcCanister : ?Text) {

    var cachedPubKey : ?[Nat8] = null;
    var cachedEvmAddr : ?Text = null;
    var localNonce : ?Nat = null;

    /// Get or cache the canister's compressed secp256k1 public key.
    public func getPublicKey() : async [Nat8] {
      switch (cachedPubKey) {
        case (?pk) { pk };
        case (null) {
          let result = await IC.ic.ecdsa_public_key({
            key_id = { name = ecdsaKeyName; curve = #secp256k1 };
            canister_id = null;
            derivation_path = [];
          });
          let pk = Blob.toArray(result.public_key);
          cachedPubKey := ?pk;
          pk;
        };
      };
    };

    /// Get or derive the canister's EVM address.
    public func getEvmAddress() : async Text {
      switch (cachedEvmAddr) {
        case (?addr) { addr };
        case (null) {
          let pk = await getPublicKey();
          let addr = switch (EvmAddress.fromCompressedPublicKey(pk)) {
            case (#ok(a)) { a };
            case (#err(_)) { "" };
          };
          cachedEvmAddr := ?addr;
          addr;
        };
      };
    };

    /// Send a generic EVM transaction with arbitrary calldata.
    /// Returns the tx hash on success.
    public func sendTransaction(
      chainId : Nat,
      toAddress : Text,
      calldata : [Nat8],
      gasLimit : Nat,
    ) : async { #ok : Text; #err : Text } {
      try {
        let pubKey = await getPublicKey();
        let senderAddr = await getEvmAddress();

        let rpcPrincipal = switch (evmRpcCanister) {
          case (?p) { p };
          case (null) { EvmRpc.DEFAULT_CANISTER };
        };
        let evmRpc : EvmRpc.EvmRpcCanister = actor (rpcPrincipal);
        let services = switch (EvmRpc.rpcServices(chainId)) {
          case (?s) { s };
          case (null) { return #err("Unsupported chain ID: " # Nat.toText(chainId)) };
        };

        // Get nonce
        let nonce = switch (localNonce) {
          case (?n) { n };
          case (null) {
            let result = await (with cycles = EvmRpc.RPC_CYCLES) evmRpc.eth_getTransactionCount(
              services, null, { address = senderAddr; block = #Latest },
            );
            switch (result) {
              case (#Consistent(#Ok(n))) { n };
              case (_) { return #err("Failed to get EVM nonce") };
            };
          };
        };

        // Get fee data
        let (maxFee, priorityFee) = await getFeeData(evmRpc, services);

        // Build unsigned tx
        let txParams : EvmUtils.TxParams = {
          chainId;
          nonce;
          maxPriorityFeePerGas = priorityFee;
          maxFeePerGas = maxFee;
          gasLimit;
          to = EvmUtils.addressToBytes(toAddress);
          value = 0;
          data = calldata;
        };
        let txHash = EvmUtils.unsignedTxHash(txParams);

        // Sign (auto-cycles via ic mops package)
        let signResult = await Call.signWithEcdsa({
          key_id = { name = ecdsaKeyName; curve = #secp256k1 };
          derivation_path = [];
          message_hash = Blob.fromArray(txHash);
        });
        let sigBytes = Blob.toArray(signResult.signature);
        let r = Array.subArray(sigBytes, 0, 32);
        let s = Array.subArray(sigBytes, 32, 32);

        let yParity = EvmAddress.recoverYParity(txHash, r, s, pubKey);

        // Submit
        let rawTxBytes = EvmUtils.signedRawTx(txParams, r, s, yParity);
        let rawTxHex = EvmUtils.bytesToHex(rawTxBytes);

        let sendResult = await (with cycles = EvmRpc.RPC_CYCLES) evmRpc.eth_sendRawTransaction(services, null, rawTxHex);
        switch (sendResult) {
          case (#Consistent(#Ok(#Ok(?hash)))) {
            localNonce := ?(nonce + 1);
            #ok(hash);
          };
          case (#Consistent(#Ok(#Ok(null)))) {
            localNonce := ?(nonce + 1);
            #ok(rawTxHex);
          };
          case (#Consistent(#Ok(#NonceTooLow))) {
            localNonce := null;
            #err("Nonce too low — retry");
          };
          case (#Consistent(#Ok(#NonceTooHigh))) { #err("Nonce too high") };
          case (#Consistent(#Ok(#InsufficientFunds))) { #err("Insufficient ETH for gas") };
          case (#Consistent(#Err(e))) { #err("RPC error: " # EvmRpc.rpcErrorToText(e)) };
          case (#Inconsistent(_)) { #err("Inconsistent RPC responses") };
        };
      } catch (e) {
        #err("EVM tx failed: " # Error.message(e));
      };
    };

    /// Send an ERC-20 `transfer(address,uint256)` transaction.
    public func sendErc20Transfer(
      chainId : Nat,
      tokenAddress : Text,
      recipientAddress : Text,
      amount : Nat,
    ) : async { #ok : Text; #err : Text } {
      let selector = EvmUtils.functionSelector("transfer(address,uint256)");
      let recipientBytes = EvmUtils.hexToBytes(recipientAddress);
      let calldata = EvmUtils.abiEncodeFunctionCall(
        selector,
        [
          #static_(EvmUtils.natToBytes(EvmUtils.bytesToNat(recipientBytes), 32)),
          #static_(EvmUtils.abiEncodeUint256(amount)),
        ],
      );
      await sendTransaction(chainId, tokenAddress, calldata, 65_000);
    };

    /// Execute an EIP-3009 `transferWithAuthorization` on a USDC contract.
    /// The canister acts as its own facilitator — it pays gas to execute
    /// the payer's signed authorization.
    public func executeTransferWithAuthorization(
      chainId : Nat,
      tokenAddress : Text,
      from : [Nat8],       // 20 bytes
      to : [Nat8],         // 20 bytes
      value : Nat,
      validAfter : Nat,
      validBefore : Nat,
      authNonce : [Nat8],  // 32 bytes
      v : Nat8,
      r : [Nat8],          // 32 bytes
      s : [Nat8],          // 32 bytes
    ) : async { #ok : Text; #err : Text } {
      // Build transferWithAuthorization calldata
      // selector: 0xe3ee160e
      let selector : [Nat8] = [0xe3, 0xee, 0x16, 0x0e];
      let calldata = EvmUtils.abiEncodeFunctionCall(
        selector,
        [
          #static_(EvmUtils.natToBytes(EvmUtils.bytesToNat(from), 32)),     // from (address)
          #static_(EvmUtils.natToBytes(EvmUtils.bytesToNat(to), 32)),       // to (address)
          #static_(EvmUtils.abiEncodeUint256(value)),                       // value
          #static_(EvmUtils.abiEncodeUint256(validAfter)),                  // validAfter
          #static_(EvmUtils.abiEncodeUint256(validBefore)),                 // validBefore
          #static_(authNonce),                                               // nonce (bytes32)
          #static_(EvmUtils.abiEncodeUint256(Nat8.toNat(v))),              // v (uint8 as uint256)
          #static_(r),                                                       // r (bytes32)
          #static_(s),                                                       // s (bytes32)
        ],
      );
      // transferWithAuthorization uses more gas than a simple transfer (~80k)
      await sendTransaction(chainId, tokenAddress, calldata, 120_000);
    };

    func getFeeData(evmRpc : EvmRpc.EvmRpcCanister, services : EvmRpc.RpcServices) : async (Nat, Nat) {
      try {
        let result = await (with cycles = EvmRpc.RPC_CYCLES) evmRpc.eth_feeHistory(
          services, null,
          { blockCount = 1; newestBlock = #Latest; rewardPercentiles = null },
        );
        switch (result) {
          case (#Consistent(#Ok(history))) {
            let baseFee = if (history.baseFeePerGas.size() > 1) {
              history.baseFeePerGas[1];
            } else if (history.baseFeePerGas.size() > 0) {
              history.baseFeePerGas[0];
            } else {
              1_000_000_000;
            };
            let minPriority = 1_000_000;
            let priorityFee = if (baseFee > 1_500_000_000) { 1_500_000_000 }
              else if (baseFee > minPriority) { baseFee }
              else { minPriority };
            (2 * baseFee + priorityFee, priorityFee);
          };
          case (_) { (100_000_000, 10_000_000) };
        };
      } catch (_) {
        (100_000_000, 10_000_000);
      };
    };
  };
};
