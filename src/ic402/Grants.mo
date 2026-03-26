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
import HMAC "mo:hmac";
import Utils "Utils";

module {

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
    /// Returns true if the seed was initialized, false if already set (from stable state or prior call).
    public func initHmacSeed(randomBlob : Blob) : Bool {
      if (hmacSeedInitialized) { return false };
      let bytes = Blob.toArray(randomBlob);
      var seed : Nat = 0;
      for (b in bytes.vals()) {
        seed := seed * 256 + Nat8.toNat(b);
      };
      hmacSeed := seed;
      hmacSeedInitialized := true;
      true;
    };

    // M-9: Constant-time comparison to prevent timing side-channels on HMAC
    func constantTimeEqual(a : Blob, b : Blob) : Bool {
      let aBytes = Blob.toArray(a);
      let bBytes = Blob.toArray(b);
      if (aBytes.size() != bBytes.size()) return false;
      var acc : Nat8 = 0;
      var i = 0;
      while (i < aBytes.size()) {
        acc := acc | (aBytes[i] ^ bBytes[i]);
        i += 1;
      };
      acc == 0;
    };

    // C-2: Include contentRefId in HMAC to bind grant to specific content
    func computeGrantHmac(grantId : Text, contentRefId : Text, grantee : Principal, expiresAt : Int) : Blob {
      let message = grantId # "|" # contentRefId # "|" # Principal.toText(grantee) # "|" # Int.toText(expiresAt);
      let msgBytes = Blob.toArray(Text.encodeUtf8(message));
      HMAC.generate(hmacSecret(), msgBytes.vals(), #sha256);
    };

    /// Issue an access grant after successful payment.
    /// Traps if HMAC seed has not been initialized (fail-safe).
    public func issueGrant(
      contentRef : Types.ContentRef,
      grantee : Principal,
      receiptId : Text,
      ttlNanos : Int,
    ) : Types.AccessGrant {
      assert(hmacSeedInitialized); // H-1: Reject grants before seed is set
      grantCounter += 1;
      let grantId = "grant-" # Nat.toText(grantCounter);
      let now = Time.now();
      let expiresAt = now + ttlNanos;
      let hmac = computeGrantHmac(grantId, contentRef.id, grantee, expiresAt);

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
        case (?_) { return #revoked("Grant " # grant.grantId # " has been revoked") };
        case (null) {};
      };

      if (Time.now() > grant.expiresAt) {
        return #expired("Grant " # grant.grantId # " expired");
      };

      let expected = computeGrantHmac(grant.grantId, grant.contentRef.id, grant.grantee, grant.expiresAt);
      if (not constantTimeEqual(expected, grant.hmac)) {
        return #invalidGrant("HMAC mismatch for grant " # grant.grantId);
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
