/// ic402 — threshold Schnorr signer (low-level primitive).
///
/// Signs arbitrary messages with the canister's threshold Schnorr key, in either
/// Ed25519 or BIP340-secp256k1. Sits beside `EvmSigner` (threshold ECDSA) and shares
/// nothing with it: a different key type, a different management-canister method, and
/// — deliberately — a caller-supplied derivation path.
///
/// This module is a PRIMITIVE and nothing more. It holds no policy, no spend caps and
/// no audit log. The calling canister is expected to wrap it and enforce its own rule
/// that no signature leaves without a policy check and a log entry. To keep that
/// wrapper's job possible, this module:
///
///  - never retries internally. A `SYS_UNKNOWN` / `CANISTER_ERROR` reject does NOT mean
///    no signature was produced ("the signature may exist in the system even though it's
///    not returned to the requesting canister" — IC interface spec), so a retry could
///    hand out two signatures for one authorised request. One call in, at most one
///    signature out.
///  - keeps no state beyond the public-key cache, and nothing in stable memory. Declare
///    the class `transient let` in a `persistent actor`, as the example does.
///  - validates input up front. Oversized arguments TRAP the calling canister when the
///    outgoing call is built (`ic0.call_data_append` "traps if the total appended data
///    exceeds the maximum inter-canister call payload"), which a caller cannot catch —
///    so the bounds below are enforced before the call is constructed.
///
/// ## Derivation paths
///
/// `derivationPath` is a required parameter on every method and is never defaulted.
/// A published address or key becomes permanent the moment a customer uses it, so the
/// choice belongs to the caller, not to this library. (`EvmSigner` hardcodes `[]` for
/// its four ECDSA sites; that is deliberate and unchanged.)
///
/// ## Usage
///
/// ```motoko
/// transient let schnorr = SchnorrSigner.SchnorrSigner("key_1");
///
/// switch (await schnorr.getPublicKey(#ed25519, [Text.encodeUtf8("agent-1")])) {
///   case (#ok({ publicKey; chainCode })) { /* 32-byte RFC8032 key */ };
///   case (#err(e)) { /* fail closed */ };
/// };
///
/// switch (await schnorr.sign(#ed25519, [Text.encodeUtf8("agent-1")], msg, null)) {
///   case (#ok(sig)) { /* 64-byte signature */ };
///   case (#err(e)) { /* fail closed */ };
/// };
/// ```
///
/// ## Key names
///
/// The Schnorr key names are the SAME as the ECDSA ones — the algorithm is a separate
/// field of `key_id`, not part of the name: `dfx_test_key` (local replica), `test_key_1`
/// (mainnet test key, 13-node subnet) and `key_1` (mainnet production, 34-node fiduciary
/// subnet). Pass the name to the constructor, as with `EvmSigner`.

import Blob "mo:base/Blob";
import Array "mo:base/Array";
import Nat "mo:base/Nat";
import Nat8 "mo:base/Nat8";
import Text "mo:base/Text";
import Error "mo:base/Error";
import HashMap "mo:base/HashMap";
import IC "mo:ic";
import ICTypes "mo:ic/Types";
import Call "mo:ic/Call";
import Utils "Utils";

module {

  /// Which Schnorr variant to sign with. Mirrors `mo:ic`'s `SchnorrAlgorithm`.
  public type Algorithm = ICTypes.SchnorrAlgorithm; // { #ed25519; #bip340secp256k1 }

  /// Auxiliary signing parameter. Only `#bip341` exists, and only for
  /// `#bip340secp256k1` — supplying it with `#ed25519` is rejected.
  public type Aux = ICTypes.SchnorrAux; // { #bip341 : { merkle_root_hash : Blob } }

  /// A derived threshold public key, with the chain code that accompanies it.
  ///
  /// `chainCode` is returned by the management canister alongside the key and is kept
  /// rather than discarded: without it a consumer cannot do BIP32-style off-chain
  /// subkey derivation, and since a published key is permanent that would be a one-way
  /// door. Callers that don't need it can ignore the field.
  ///
  /// Encoding differs per algorithm:
  ///  - `#ed25519` — `publicKey` is the 32-byte RFC8032 compressed point, usable as-is.
  ///  - `#bip340secp256k1` — `publicKey` is the 33-byte SEC1-COMPRESSED key. BIP340
  ///    verification needs the 32-byte x-only form; use `xOnlyFromCompressed`.
  public type PublicKey = {
    publicKey : [Nat8];
    chainCode : [Nat8];
  };

  // ── Bounds ──
  //
  // The IC documents no Schnorr-specific message cap; the operative limit is the generic
  // inter-canister payload (2 MiB cross-subnet, 10 MiB same-subnet). The signing key
  // always lives on a different subnet from the caller, so 2 MiB is the ceiling that
  // applies. We cap well under it: the Candid payload also carries the derivation path,
  // key name and aux, and exceeding the limit traps rather than rejects.

  /// Largest message this module will submit for signing (1 MiB).
  /// Chosen for headroom under the 2 MiB cross-subnet payload limit, not mandated by spec.
  public let MAX_MESSAGE_BYTES : Nat = 1_048_576;

  /// Maximum number of derivation-path elements a CALLER may supply: 254, not 255.
  ///
  /// The spec's "at most 255" is the total length of the extended-BIP32 path, and the IC
  /// prepends the calling canister's own id as the first element — so 254 is what is left
  /// for the caller. Verified against a live replica: 254 elements succeed, 255 is rejected
  /// by the management canister's Candid decoder with "The number of elements exceeds
  /// maximum allowed 254". Capping at 255 here would let that one value through validation
  /// and fail on a wasted cross-subnet round trip, with an opaque decoder message instead of
  /// this module's own error.
  public let MAX_DERIVATION_PATH_ELEMENTS : Nat = 254;

  /// Maximum total bytes across all derivation-path elements (8 KiB).
  /// The spec places no per-element cap ("each byte string may be of arbitrary length,
  /// including empty"), so this is our own bound to keep the outgoing payload predictable.
  public let MAX_DERIVATION_PATH_BYTES : Nat = 8_192;

  // ── Pure helpers (module scope — unit-testable without a replica) ──
  //
  // `mops test` runs in the Motoko interpreter, where the cost primitive
  // `costSignWithSchnorr` is unimplemented and `mo:ic/Call`'s async surface cannot be
  // reached at all. Every signing path is therefore replica-only. Keeping validation
  // and encoding out here as pure functions is what makes any of this unit-testable —
  // the same split `EvmSender` uses for its fee helpers.

  /// Reject a message that is empty or larger than `MAX_MESSAGE_BYTES`.
  ///
  /// Empty is rejected by choice, not by platform rule: the replica has no
  /// `message.is_empty()` check on the decoded field, so an empty message would likely
  /// be signed. A signature over nothing is almost always a caller bug, and this module
  /// fails closed.
  public func validateMessage(message : Blob) : { #ok; #err : Text } {
    let n = message.size();
    if (n == 0) { return #err("Message is empty") };
    if (n > MAX_MESSAGE_BYTES) {
      return #err("Message too large: " # Nat.toText(n) # " bytes, max " # Nat.toText(MAX_MESSAGE_BYTES));
    };
    #ok;
  };

  /// Reject a derivation path with too many elements or too many total bytes.
  /// An empty path is valid and means "the canister's own root key".
  public func validateDerivationPath(derivationPath : [Blob]) : { #ok; #err : Text } {
    if (derivationPath.size() > MAX_DERIVATION_PATH_ELEMENTS) {
      return #err(
        "Derivation path too long: " # Nat.toText(derivationPath.size())
        # " elements, max " # Nat.toText(MAX_DERIVATION_PATH_ELEMENTS)
      );
    };
    var total : Nat = 0;
    for (element in derivationPath.vals()) { total += element.size() };
    if (total > MAX_DERIVATION_PATH_BYTES) {
      return #err(
        "Derivation path too large: " # Nat.toText(total)
        # " bytes, max " # Nat.toText(MAX_DERIVATION_PATH_BYTES)
      );
    };
    #ok;
  };

  /// Reject an aux that the algorithm does not accept, or a malformed merkle root.
  ///
  /// `#bip341` is valid only for `#bip340secp256k1`. Its `merkle_root_hash` must be
  /// either empty (key-path-only spend, no script tree) or exactly 32 bytes — the spec
  /// says it "SHOULD be either an empty bytestring or a 32-byte value"; we enforce it,
  /// because anything else silently changes which key the signature verifies against.
  public func validateAux(algorithm : Algorithm, aux : ?Aux) : { #ok; #err : Text } {
    switch (aux) {
      case (null) { #ok };
      case (?#bip341({ merkle_root_hash })) {
        switch (algorithm) {
          case (#ed25519) {
            #err("bip341 aux is not supported for ed25519 — it applies only to bip340secp256k1");
          };
          case (#bip340secp256k1) {
            let n = merkle_root_hash.size();
            if (n == 0 or n == 32) { #ok } else {
              #err("bip341 merkle_root_hash must be empty or 32 bytes, got " # Nat.toText(n));
            };
          };
        };
      };
    };
  };

  /// Convert a 33-byte SEC1-compressed secp256k1 key to the 32-byte x-only form that
  /// BIP340 verification requires, by dropping the leading parity byte.
  ///
  /// "To use BIP32 public keys to verify BIP340 Schnorr signatures, the first byte of
  /// the (33-byte) SEC1-encoded public key must be removed" — IC interface spec.
  /// Only meaningful for `#bip340secp256k1`; an Ed25519 key is already 32 bytes.
  public func xOnlyFromCompressed(publicKey : [Nat8]) : { #ok : [Nat8]; #err : Text } {
    if (publicKey.size() != 33) {
      return #err("Expected a 33-byte compressed secp256k1 key, got " # Nat.toText(publicKey.size()));
    };
    let prefix = publicKey[0];
    if (prefix != 0x02 and prefix != 0x03) {
      return #err("Not a compressed secp256k1 key: leading byte is 0x" # hexNoPrefix([prefix]));
    };
    #ok(Array.tabulate<Nat8>(32, func(i) { publicKey[i + 1] }));
  };

  /// Lowercase hex, NO `0x` prefix.
  ///
  /// Deliberately not `EvmUtils.bytesToHex`, which prefixes with `0x`. `cacheKey` needs a
  /// fixed-width, hex-alphabet-only encoding for its injectivity argument below; borrowing
  /// a helper that prefixes would make that property an accident of an unrelated function's
  /// formatting, and a later change there would silently create cache collisions.
  func hexNoPrefix(bytes : [Nat8]) : Text {
    let digits = ["0", "1", "2", "3", "4", "5", "6", "7", "8", "9", "a", "b", "c", "d", "e", "f"];
    var out = "";
    for (b in bytes.vals()) {
      let n = Nat8.toNat(b);
      out #= digits[n / 16] # digits[n % 16];
    };
    out;
  };

  /// Stable cache key for an (algorithm, derivationPath) pair.
  ///
  /// The algorithm tag is included because one key NAME serves both algorithms — caching on
  /// the path alone would hand back an Ed25519 key for a BIP340 request.
  ///
  /// INJECTIVITY: each element is emitted as `/` followed by fixed-width hex (two chars per
  /// byte, drawn from `0-9a-f`). `/` is outside that alphabet, so it is unambiguously an
  /// element boundary and no two distinct paths share an encoding — `["ab","cd"]` gives
  /// `/ab/cd` where `["abcd"]` gives `/abcd`. The separator is the load-bearing part; remove
  /// it and the two collide.
  public func cacheKey(algorithm : Algorithm, derivationPath : [Blob]) : Text {
    let tag = switch (algorithm) {
      case (#ed25519) { "ed25519" };
      case (#bip340secp256k1) { "bip340secp256k1" };
    };
    Utils.derivationCacheKey(tag, derivationPath);
  };

  // ── Signer ──

  /// Threshold Schnorr signer over a single key name.
  ///
  /// Holds only a public-key cache. Declare it `transient let` — its state is derivable
  /// and must never reach stable memory.
  public class SchnorrSigner(schnorrKeyName : Text) {

    // Keyed by `cacheKey(algorithm, derivationPath)`. Public keys are stable for the
    // life of the key and free to fetch (schnorr_public_key costs no cycles), so this
    // is a latency cache, not a correctness one. Only successes are cached — a failed
    // lookup must be retryable (the C2 lesson from EvmSigner's address cache).
    var cachedKeys = HashMap.HashMap<Text, PublicKey>(8, Text.equal, Text.hash);

    /// The key name this signer was constructed with.
    public func keyName() : Text { schnorrKeyName };

    /// Cycles the next `sign` call will attach, for this key name and algorithm.
    ///
    /// Read from the replica at call time via the system API — there is no constant to
    /// quote, and the figure depends on the subnet the KEY lives on, not the caller's.
    /// Returns `#err` for a key name the replica does not recognise, which is also how
    /// a bad key name is caught before any signing call is made.
    ///
    /// Not callable under `mops test` (the interpreter has no `costSignWithSchnorr`).
    public func signatureCost(algorithm : Algorithm) : { #ok : Nat; #err : Text } {
      switch (Call.Cost.signWithSchnorr(schnorrKeyName, algorithm)) {
        case (#ok(cycles)) { #ok(cycles) };
        case (#err(#invalidKeyName)) {
          #err("Unknown Schnorr key name: " # schnorrKeyName);
        };
      };
    };

    /// Fetch (and cache) the threshold public key for an (algorithm, path) pair.
    ///
    /// Costs no cycles. Deterministic: the same pair always yields the same key, and
    /// different paths yield different keys.
    public func getPublicKey(
      algorithm : Algorithm,
      derivationPath : [Blob],
    ) : async { #ok : PublicKey; #err : Text } {
      switch (validateDerivationPath(derivationPath)) {
        case (#err(e)) { return #err(e) };
        case (#ok) {};
      };

      let key = cacheKey(algorithm, derivationPath);
      switch (cachedKeys.get(key)) {
        case (?hit) { return #ok(hit) };
        case (null) {};
      };

      try {
        let result = await IC.ic.schnorr_public_key({
          key_id = { algorithm; name = schnorrKeyName };
          canister_id = null;
          derivation_path = derivationPath;
        });
        let derived : PublicKey = {
          publicKey = Blob.toArray(result.public_key);
          chainCode = Blob.toArray(result.chain_code);
        };
        // Cache only on success — a transient failure must not be memoised.
        cachedKeys.put(key, derived);
        #ok(derived);
      } catch (e) {
        #err("Schnorr public key lookup failed: " # Error.message(e));
      };
    };

    /// Sign `message` with the threshold key at (algorithm, derivationPath).
    ///
    /// `aux` carries the BIP341 taproot tweak for key-path spends and is valid only for
    /// `#bip340secp256k1`. When supplied, the signature verifies against the TWEAKED
    /// output key — not the key `getPublicKey` returns, which is BIP341's
    /// `internal_pubkey`. The caller must apply the tweak before verifying.
    ///
    /// Returns the raw signature: 64 bytes for both algorithms. Ed25519 threshold
    /// signatures are NON-DETERMINISTIC — signing the same message twice yields
    /// different bytes, so compare by verification, never by equality.
    ///
    /// No retry on failure, by design: a `SYS_UNKNOWN` / `CANISTER_ERROR` reject does
    /// not prove the signature was not produced, so retrying risks two signatures for
    /// one request. The caller decides whether to re-request, with its own policy check.
    public func sign(
      algorithm : Algorithm,
      derivationPath : [Blob],
      message : Blob,
      aux : ?Aux,
    ) : async { #ok : [Nat8]; #err : Text } {
      switch (validateMessage(message)) {
        case (#err(e)) { return #err(e) };
        case (#ok) {};
      };
      switch (validateDerivationPath(derivationPath)) {
        case (#err(e)) { return #err(e) };
        case (#ok) {};
      };
      switch (validateAux(algorithm, aux)) {
        case (#err(e)) { return #err(e) };
        case (#ok) {};
      };

      try {
        // trySignWithSchnorr, not signWithSchnorr: the non-try variant TRAPS when the
        // cost lookup fails on an unknown key name, which a caller cannot catch. This
        // module fails closed with an error instead.
        let result = await Call.trySignWithSchnorr({
          key_id = { algorithm; name = schnorrKeyName };
          derivation_path = derivationPath;
          message;
          aux;
        });
        switch (result) {
          case (#ok({ signature })) { #ok(Blob.toArray(signature)) };
          case (#err(#invalidKeyName)) {
            #err("Unknown Schnorr key name: " # schnorrKeyName);
          };
        };
      } catch (e) {
        #err("Schnorr signing failed: " # Error.message(e));
      };
    };

    /// Convenience: the x-only (32-byte) BIP340 key for a derivation path.
    /// Fails for `#ed25519`, whose key is not in SEC1 form.
    public func getBip340XOnlyKey(derivationPath : [Blob]) : async { #ok : [Nat8]; #err : Text } {
      switch (await getPublicKey(#bip340secp256k1, derivationPath)) {
        case (#err(e)) { #err(e) };
        case (#ok({ publicKey })) { xOnlyFromCompressed(publicKey) };
      };
    };

    /// Drop every cached public key. Only useful in tests and after a key rotation;
    /// derived keys are otherwise stable for the life of the key name.
    public func clearCache() {
      cachedKeys := HashMap.HashMap<Text, PublicKey>(8, Text.equal, Text.hash);
    };
  };
};
