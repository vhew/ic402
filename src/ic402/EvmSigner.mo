/// ic402 — EVM remote signer (sign-only mode).
///
/// Signs EVM transactions using the canister's threshold ECDSA key
/// but does NOT broadcast them. The client library handles RPC submission.
///
/// This eliminates EVM RPC calls from the canister, reducing cycles cost
/// by 40-85% for outbound operations while maintaining the same security:
/// the canister still enforces spending policy before signing.
///
/// Usage:
/// ```motoko
/// transient let signer = EvmSigner.EvmSigner("dfx_test_key");
/// let { rawTx; txHash } = await signer.signErc20Transfer(chainId, token, to, amount, nonce, maxFee, priorityFee);
/// // Client broadcasts rawTx via their own RPC provider
/// ```

import EvmUtils "EvmUtils";
import EvmAddress "EvmAddress";
import Blob "mo:base/Blob";
import Array "mo:base/Array";
import Nat "mo:base/Nat";
import Nat8 "mo:base/Nat8";
import Int "mo:base/Int";
import Time "mo:base/Time";
import Text "mo:base/Text";
import Error "mo:base/Error";
import IC "mo:ic";
import Call "mo:ic/Call";
import Eip712 "Eip712";
import Utils "Utils";

module {

  /// Signed EVM transaction ready for client-side broadcast.
  public type SignedTransaction = {
    rawTx : Text;     // 0x-prefixed hex RLP-encoded signed tx
    txHash : Text;     // 0x-prefixed hash of the unsigned tx (for tracking)
  };

  /// Signed EIP-3009 authorization for x402 payment headers.
  public type SignedAuthorization = {
    header : Text;     // Base64-encoded x402 v2 payment header
    paidAmount : Nat;  // Amount authorized (token smallest unit)
    authorization : {  // Raw fields for client verification
      from : Text;
      to : Text;
      value : Nat;
      validAfter : Nat;
      validBefore : Nat;
      nonce : Text;    // hex
      signature : Text; // hex (r || s || v)
    };
  };

  /// Signed EIP-712 typed data — the generic signing primitive.
  /// Used for DEX agent wallet registration, trading actions, and any protocol
  /// that uses EIP-712 for off-chain signed messages.
  public type SignedTypedData = {
    signature : Text;  // 0x-prefixed hex (r || s || v, 65 bytes = 130 hex chars)
    signer : Text;     // signer's EVM address (0x-prefixed)
    digest : Text;     // the EIP-712 digest that was signed (0x-prefixed hex)
    v : Nat8;
    r : Text;          // 0x-prefixed hex, 32 bytes
    s : Text;          // 0x-prefixed hex, 32 bytes
  };

  /// EVM transaction signer using canister's tECDSA key.
  /// Does not make any EVM RPC calls — the client provides chain state
  /// (nonce, gas prices) and handles broadcasting.
  public class EvmSigner(ecdsaKeyName : Text) {

    var cachedPubKey : ?[Nat8] = null;
    var cachedEvmAddr : ?Text = null;
    // M-6: nonceCounter removed — was not persisted across upgrades.
    // Now using Time.now() (nanoseconds) which is monotonically increasing
    // within a canister (single-threaded execution guarantees uniqueness).

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

    /// Get or derive the canister's EVM address (0x-prefixed).
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

    /// Sign a generic EVM transaction. Client provides nonce and gas data.
    /// Returns the signed raw transaction hex for client-side broadcast.
    public func signTransaction(
      chainId : Nat,
      toAddress : Text,
      calldata : [Nat8],
      value : Nat,
      gasLimit : Nat,
      nonce : Nat,
      maxFeePerGas : Nat,
      maxPriorityFeePerGas : Nat,
    ) : async { #ok : SignedTransaction; #err : Text } {
      try {
        let pubKey = await getPublicKey();

        let txParams : EvmUtils.TxParams = {
          chainId;
          nonce;
          maxPriorityFeePerGas;
          maxFeePerGas;
          gasLimit;
          to = EvmUtils.addressToBytes(toAddress);
          value;
          data = calldata;
        };
        let txHash = EvmUtils.unsignedTxHash(txParams);

        let signResult = await Call.signWithEcdsa({
          key_id = { name = ecdsaKeyName; curve = #secp256k1 };
          derivation_path = [];
          message_hash = Blob.fromArray(txHash);
        });
        let sigBytes = Blob.toArray(signResult.signature);
        let r = Array.subArray(sigBytes, 0, 32);
        let s = Array.subArray(sigBytes, 32, 32);
        let yParity = EvmAddress.recoverYParity(txHash, r, s, pubKey);

        let rawTxBytes = EvmUtils.signedRawTx(txParams, r, s, yParity);
        #ok({
          rawTx = EvmUtils.bytesToHex(rawTxBytes);
          txHash = EvmUtils.bytesToHex(txHash);
        });
      } catch (e) {
        #err("Signing failed: " # Error.message(e));
      };
    };

    /// Sign an ERC-20 `transfer(address,uint256)` transaction.
    /// Client provides nonce and gas data from their own RPC.
    public func signErc20Transfer(
      chainId : Nat,
      tokenAddress : Text,
      recipientAddress : Text,
      amount : Nat,
      nonce : Nat,
      maxFeePerGas : Nat,
      maxPriorityFeePerGas : Nat,
    ) : async { #ok : SignedTransaction; #err : Text } {
      let selector = EvmUtils.functionSelector("transfer(address,uint256)");
      let recipientBytes = EvmUtils.hexToBytes(recipientAddress);
      let calldata = EvmUtils.abiEncodeFunctionCall(
        selector,
        [
          #static_(EvmUtils.natToBytes(EvmUtils.bytesToNat(recipientBytes), 32)),
          #static_(EvmUtils.abiEncodeUint256(amount)),
        ],
      );
      await signTransaction(chainId, tokenAddress, calldata, 0, 65_000, nonce, maxFeePerGas, maxPriorityFeePerGas);
    };

    /// Sign a native ETH transfer transaction.
    /// Client provides nonce and gas data from their own RPC.
    public func signEthTransfer(
      chainId : Nat,
      recipientAddress : Text,
      amountWei : Nat,
      gasLimit : Nat,
      nonce : Nat,
      maxFeePerGas : Nat,
      maxPriorityFeePerGas : Nat,
    ) : async { #ok : SignedTransaction; #err : Text } {
      await signTransaction(chainId, recipientAddress, [], amountWei, gasLimit, nonce, maxFeePerGas, maxPriorityFeePerGas);
    };

    /// Sign an EIP-3009 TransferWithAuthorization for x402 payments.
    /// Returns a base64-encoded x402 v2 payment header that the client
    /// includes as the X-Payment HTTP header.
    public func signEip3009Authorization(
      chainId : Nat,
      tokenAddress : Text,
      recipient : Text,
      amount : Nat,
      tokenName : Text,
      tokenVersion : Text,
    ) : async { #ok : SignedAuthorization; #err : Text } {
      try {
        let fromAddr = await getEvmAddress();
        let pubKey = await getPublicKey();
        let tokenAddr = EvmUtils.hexToBytes(tokenAddress);
        let now : Nat = Int.abs(Time.now() / 1_000_000_000);
        let validAfter = if (now > 600) { now - 600 } else { 0 };
        let validBefore = now + 300;

        // M-6: Use nanosecond timestamp for nonce uniqueness (survives upgrades)
        let nonceBytes = EvmUtils.natToBytes(Int.abs(Time.now()), 32);

        // EIP-712 digest
        let domSep = Eip712.domainSeparator(tokenName, tokenVersion, chainId, tokenAddr);
        let structHash = Eip712.hashTransferWithAuthorization(
          EvmUtils.hexToBytes(fromAddr),
          EvmUtils.hexToBytes(recipient),
          amount, validAfter, validBefore, nonceBytes,
        );
        let digest = Eip712.digest(domSep, structHash);

        // Sign with tECDSA
        let signResult = await Call.signWithEcdsa({
          key_id = { name = ecdsaKeyName; curve = #secp256k1 };
          derivation_path = [];
          message_hash = Blob.fromArray(digest);
        });
        let sigBytes = Blob.toArray(signResult.signature);
        let r = Array.subArray(sigBytes, 0, 32);
        let s = Array.subArray(sigBytes, 32, 32);
        let v = EvmAddress.recoverYParity(digest, r, s, pubKey);

        let sigHex = EvmUtils.bytesToHex(Array.append(Array.append(r, s), [v + 27]));
        let networkStr = "eip155:" # Nat.toText(chainId);

        // Build x402 v2 payment header
        let paymentPayload = "{\"x402Version\":2"
          # ",\"resource\":{}"
          # ",\"accepted\":{\"scheme\":\"exact\""
          # ",\"network\":\"" # networkStr # "\""
          # ",\"amount\":\"" # Nat.toText(amount) # "\""
          # ",\"asset\":\"" # tokenAddress # "\""
          # ",\"payTo\":\"" # recipient # "\""
          # ",\"maxTimeoutSeconds\":300"
          # ",\"extra\":{\"name\":\"" # Utils.escapeJsonString(tokenName) # "\",\"version\":\"" # Utils.escapeJsonString(tokenVersion) # "\"}}"
          # ",\"payload\":{\"signature\":\"" # sigHex # "\""
          # ",\"authorization\":{\"from\":\"" # fromAddr # "\""
          # ",\"to\":\"" # recipient # "\""
          # ",\"value\":\"" # Nat.toText(amount) # "\""
          # ",\"validAfter\":\"" # Nat.toText(validAfter) # "\""
          # ",\"validBefore\":\"" # Nat.toText(validBefore) # "\""
          # ",\"nonce\":\"" # EvmUtils.bytesToHex(nonceBytes) # "\""
          # "}}}";
        let header = Utils.base64Encode(Blob.toArray(Text.encodeUtf8(paymentPayload)));

        #ok({
          header;
          paidAmount = amount;
          authorization = {
            from = fromAddr;
            to = recipient;
            value = amount;
            validAfter;
            validBefore;
            nonce = EvmUtils.bytesToHex(nonceBytes);
            signature = sigHex;
          };
        });
      } catch (e) {
        #err("EIP-3009 signing failed: " # Error.message(e));
      };
    };

    /// Sign an ERC-8004 agent registration transaction.
    /// Client provides nonce and gas data from their own RPC.
    public func signRegistration(
      registryAddress : Text,
      chainId : Nat,
      card : { name : Text; description : Text; services : [{ name : Text; endpoint : Text; version : Text; skills : [Text]; domains : [Text] }]; x402Support : Bool },
      gasLimit : Nat,
      nonce : Nat,
      maxFeePerGas : Nat,
      maxPriorityFeePerGas : Nat,
    ) : async { #ok : SignedTransaction; #err : Text } {
      let service = if (card.services.size() > 0) {
        card.services[0];
      } else {
        { name = ""; endpoint = ""; version = ""; skills = [] : [Text]; domains = [] : [Text] };
      };

      let selector = EvmUtils.functionSelector("register(string,string,string,string[],string[],bool)");
      let calldata = EvmUtils.abiEncodeFunctionCall(
        selector,
        [
          #dynamic(EvmUtils.abiEncodeString(card.name)),
          #dynamic(EvmUtils.abiEncodeString(card.description)),
          #dynamic(EvmUtils.abiEncodeString(service.endpoint)),
          #dynamic(EvmUtils.abiEncodeStringArray(service.skills)),
          #dynamic(EvmUtils.abiEncodeStringArray(service.domains)),
          #static_(EvmUtils.abiEncodeBool(card.x402Support)),
        ],
      );
      await signTransaction(chainId, registryAddress, calldata, 0, gasLimit, nonce, maxFeePerGas, maxPriorityFeePerGas);
    };

    /// Sign arbitrary EIP-712 typed data.
    ///
    /// This is the generic signing primitive for any protocol that uses EIP-712:
    /// DEX agent wallet registration, trading actions, permit signatures, etc.
    ///
    /// The caller provides the pre-computed domain separator and struct hash.
    /// The canister computes the EIP-712 digest and signs it with tECDSA.
    ///
    /// For security: the consuming canister should construct the domainSeparator
    /// and structHash itself from validated parameters — do NOT pass pre-computed
    /// values from an untrusted client.
    public func signTypedData(
      domainSeparator : [Nat8], // 32 bytes: keccak256(EIP712Domain(...))
      structHash : [Nat8],      // 32 bytes: keccak256(typeHash || encodedFields)
    ) : async { #ok : SignedTypedData; #err : Text } {
      try {
        let pubKey = await getPublicKey();
        let fromAddr = await getEvmAddress();

        // EIP-712 digest: keccak256(0x19 || 0x01 || domainSeparator || structHash)
        let eip712Digest = Eip712.digest(domainSeparator, structHash);

        // Sign with tECDSA
        let signResult = await Call.signWithEcdsa({
          key_id = { name = ecdsaKeyName; curve = #secp256k1 };
          derivation_path = [];
          message_hash = Blob.fromArray(eip712Digest);
        });
        let sigBytes = Blob.toArray(signResult.signature);
        let r = Array.subArray(sigBytes, 0, 32);
        let s = Array.subArray(sigBytes, 32, 32);
        let v = EvmAddress.recoverYParity(eip712Digest, r, s, pubKey);

        let rHex = EvmUtils.bytesToHex(r);
        let sHex = EvmUtils.bytesToHex(s);
        let sigHex = EvmUtils.bytesToHex(Array.append(Array.append(r, s), [v + 27]));

        #ok({
          signature = sigHex;
          signer = fromAddr;
          digest = EvmUtils.bytesToHex(eip712Digest);
          v = v + 27;
          r = rHex;
          s = sHex;
        });
      } catch (e) {
        #err("EIP-712 signing failed: " # Error.message(e));
      };
    };
  };
};
