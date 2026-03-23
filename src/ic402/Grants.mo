/// ic402 — Access grant subsystem (HMAC-based content delivery tokens).
import Types "Types";
import Time "mo:base/Time";
import Nat "mo:base/Nat";
import Nat8 "mo:base/Nat8";
import Int "mo:base/Int";
import Text "mo:base/Text";
import Array "mo:base/Array";
import Blob "mo:base/Blob";
import HashMap "mo:base/HashMap";
import Iter "mo:base/Iter";
import Principal "mo:base/Principal";
import SHA256 "mo:sha2/Sha256";
import Utils "Utils";

module {

  // HMAC-SHA256(key, message) -> Blob
  func hmacSha256(key : [Nat8], message : [Nat8]) : Blob {
    let blockSize = 64;

    let effectiveKey : [Nat8] = if (key.size() > blockSize) {
      Blob.toArray(SHA256.fromArray(#sha256, key));
    } else {
      key;
    };

    let paddedKey = Array.tabulate<Nat8>(blockSize, func(i) : Nat8 {
      if (i < effectiveKey.size()) { effectiveKey[i] } else { 0 : Nat8 };
    });

    let ipadKey = Array.tabulate<Nat8>(blockSize, func(i) : Nat8 {
      paddedKey[i] ^ (0x36 : Nat8);
    });

    let opadKey = Array.tabulate<Nat8>(blockSize, func(i) : Nat8 {
      paddedKey[i] ^ (0x5c : Nat8);
    });

    let inner = SHA256.fromArray(#sha256, Array.append(ipadKey, message));
    SHA256.fromArray(#sha256, Array.append(opadKey, Blob.toArray(inner)));
  };

  public class Grants(canisterPrincipal : Principal) {

    var grantCounter : Nat = 0;
    var hmacSeed : Nat = 0;
    var hmacSeedInitialized : Bool = false;
    var revokedGrants = HashMap.HashMap<Text, Bool>(16, Text.equal, Text.hash);

    func hmacSecret() : [Nat8] {
      let principalBytes = Blob.toArray(Principal.toBlob(canisterPrincipal));
      let seedBytes = Utils.natToBytes8(hmacSeed);
      Blob.toArray(SHA256.fromArray(#sha256, Array.append(principalBytes, seedBytes)));
    };

    /// Initialize HMAC seed from randomness. Call once on first deployment.
    /// If already initialized (from stable state), this is a no-op.
    public func initHmacSeed(randomBlob : Blob) {
      if (not hmacSeedInitialized) {
        let bytes = Blob.toArray(randomBlob);
        var seed : Nat = 0;
        for (b in bytes.vals()) {
          seed := seed * 256 + Nat8.toNat(b);
        };
        hmacSeed := seed;
        hmacSeedInitialized := true;
      };
    };

    func computeGrantHmac(grantId : Text, grantee : Principal, expiresAt : Int) : Blob {
      let message = grantId # "|" # Principal.toText(grantee) # "|" # Int.toText(expiresAt);
      hmacSha256(hmacSecret(), Blob.toArray(Text.encodeUtf8(message)));
    };

    /// Issue an access grant after successful payment.
    public func issueGrant(
      contentRef : Types.ContentRef,
      grantee : Principal,
      receiptId : Text,
      ttlNanos : Int,
    ) : Types.AccessGrant {
      grantCounter += 1;
      let grantId = "grant-" # Nat.toText(grantCounter);
      let now = Time.now();
      let expiresAt = now + ttlNanos;
      let hmac = computeGrantHmac(grantId, grantee, expiresAt);

      {
        grantId;
        contentRef;
        grantee;
        receiptId;
        issuedAt = now;
        expiresAt;
        hmac;
      };
    };

    /// Verify an access grant (stateless HMAC check + expiry + revocation).
    public func verifyGrant(grant : Types.AccessGrant) : Types.AccessGrantResult {
      switch (revokedGrants.get(grant.grantId)) {
        case (?_) { return #revoked };
        case (null) {};
      };

      if (Time.now() > grant.expiresAt) {
        return #expired;
      };

      let expected = computeGrantHmac(grant.grantId, grant.grantee, grant.expiresAt);
      if (expected != grant.hmac) {
        return #invalidGrant;
      };

      #ok;
    };

    /// Revoke a grant (e.g., after refund).
    public func revokeGrant(grantId : Text) : Bool {
      switch (revokedGrants.get(grantId)) {
        case (?_) { false };
        case (null) {
          revokedGrants.put(grantId, true);
          true;
        };
      };
    };

    // ── Stable state ──

    public func toStable() : Types.StableAccessGrantState {
      {
        revokedGrantIds = Iter.toArray(
          Iter.map<(Text, Bool), Text>(
            revokedGrants.entries(),
            func((id, _)) { id },
          )
        );
        grantCounter;
        hmacSeed;
      };
    };

    public func loadStable(data : Types.StableAccessGrantState) {
      grantCounter := data.grantCounter;
      hmacSeed := data.hmacSeed;
      hmacSeedInitialized := (hmacSeed > 0);
      revokedGrants := HashMap.HashMap<Text, Bool>(
        data.revokedGrantIds.size(), Text.equal, Text.hash,
      );
      for (id in data.revokedGrantIds.vals()) {
        revokedGrants.put(id, true);
      };
    };
  };
};
