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
import Array "mo:base/Array";
import Principal "mo:base/Principal";
import SHA256 "mo:sha2/Sha256";
import Ed25519 "mo:ed25519";
import IC "mo:ic";

module {

  // RFC 8410 SubjectPublicKeyInfo prefix for a raw Ed25519 key:
  // SEQUENCE(44) { SEQUENCE(5) { OID 1.3.101.112 }, BIT STRING(33, 0 unused) } ‖ key.
  // Byte-for-byte what @icp-sdk/agent-js produces via getPublicKey().toDer().
  let DER_ED25519_SPKI_PREFIX : [Nat8] = [0x30, 0x2A, 0x30, 0x05, 0x06, 0x03, 0x2B, 0x65, 0x70, 0x03, 0x21, 0x00];

  /// The IC self-authenticating principal for a raw 32-byte Ed25519 public key:
  /// SHA-224(DER-SPKI(pubkey)) ‖ 0x02 (29 bytes — IC interface spec, "special forms of ids").
  /// null if `pubkey` is not exactly 32 bytes.
  ///
  /// Ed25519 ONLY, and opportunistic by design: a caller whose IC identity is secp256k1/P-256,
  /// or who calls through an Internet Identity delegation, derives a DIFFERENT principal and
  /// will not match — a mismatch means "not identity-bound", never "invalid".
  public func selfAuthPrincipalOfEd25519(pubkey : Blob) : ?Blob {
    let raw = Blob.toArray(pubkey);
    if (raw.size() != 32) { return null };
    let der = Blob.fromArray(Array.append<Nat8>(DER_ED25519_SPKI_PREFIX, raw));
    let digest = Blob.toArray(SHA256.fromBlob(#sha224, der));
    ?Blob.fromArray(Array.append<Nat8>(digest, [0x02]));
  };

  /// True iff `pubkey` self-authenticates `caller` (see selfAuthPrincipalOfEd25519) AND
  /// `signature` is a valid Ed25519 signature by that key over `message` — i.e. the caller
  /// both OWNS the key (it derives their principal) and POSSESSES it (they signed with it).
  ///
  /// Wrong-length inputs return false. KNOWN SHARP EDGE (shared with the voucher verify in
  /// Sessions.consumeVoucher): a 64-byte signature whose R is not a valid curve-point encoding
  /// makes mo:ed25519 TRAP rather than return false — benign (the message rolls back, no state
  /// change) but callers on adversarial input see a canister_error instead of `false`.
  public func verifyCallerEd25519(caller : Principal, pubkey : Blob, signature : Blob, message : Blob) : Bool {
    if (signature.size() != 64) { return false };
    switch (selfAuthPrincipalOfEd25519(pubkey)) {
      case (?p) {
        if (p != Principal.toBlob(caller)) { return false };
        Ed25519.ED25519.verify(Blob.toArray(signature), Blob.toArray(message), Blob.toArray(pubkey));
      };
      case (null) { false };
    };
  };

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
      // evmAddress starts null on a fresh instance, so this is a plain restore (the old
      // no-op-on-null switch was equivalent). NB: ContentStore.loadStable's null branch is
      // deliberately different — there it preserves the in-memory value.
      evmAddress := data.evmAddress;
    };
  };
};
