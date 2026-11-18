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
import Buffer "mo:base/Buffer";
import Iter "mo:base/Iter";
import Principal "mo:base/Principal";
import SHA256 "mo:sha2/Sha256";
import HMAC "mo:hmac";
import Utils "Utils";
import Debug "mo:base/Debug";

module {

  /// 2.22.0: how long a revocation is kept (gcRevokedGrants), and so the longest grant lifetime
  /// issueGrant gives: a revoked grant must expire before its revocation is forgotten.
  public let MAX_GRANT_TTL_NS : Int = 604_800_000_000_000; // 7 days in nanoseconds

  /// 2.22.0: whether a grant id or content id can go into the grant HMAC. The HMAC message joins
  /// the fields with '|', so a field containing '|' could be split another way: a grant for
  /// content "a|b" would also verify as grant "<id>|a" for content "b".
  public func grantFieldOk(field : Text) : Bool { not Text.contains(field, #char '|') };

  /// HMAC-based access grant manager for content delivery tokens.
  public class Grants(canisterPrincipal : Principal) {

    var grantCounter : Nat = 0;
    var hmacSeed : Nat = 0;
    var hmacSeedInitialized : Bool = false;
    // M-1: Store revocation timestamps so old entries can be garbage-collected.
    var revokedGrants = HashMap.HashMap<Text, Int>(16, Text.equal, Text.hash);

    func hmacSecret() : [Nat8] {
      let principalBytes = Blob.toArray(Principal.toBlob(canisterPrincipal));
      // M-1/M-8: Use the FULL-width seed bytes. initHmacSeed stores the entire
      // 256-bit randomness in `hmacSeed`; the previous natToBytes8 truncated it
      // to the low 64 bits, silently dropping ~192 bits of entropy.
      let seedBytes = Utils.natToBytesBE(hmacSeed);
      Blob.toArray(SHA256.fromArray(#sha256, Array.append(principalBytes, seedBytes)));
    };

    /// 2.22.0: whether issueGrant can issue: the HMAC seed is set (initHmacSeed, or restored by
    /// loadStable). Once true it stays true.
    public func grantsReady() : Bool { hmacSeedInitialized };

    /// Initialize HMAC seed from randomness. Call once on first deployment.
    /// Returns true if the seed was initialized, false if already set (from stable state or prior call).
    public func initHmacSeed(randomBlob : Blob) : Bool {
      if (hmacSeedInitialized) { return false };
      let bytes = Blob.toArray(randomBlob);
      var seed : Nat = 0;
      for (b in bytes.values()) {
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
      HMAC.generate(hmacSecret(), msgBytes.values(), #sha256);
    };

    /// Issue an access grant after successful payment.
    /// Traps with descriptive message if HMAC seed has not been initialized.
    /// 2.22.0: also traps if contentRef.id contains '|' (see grantFieldOk). A trap after a payment
    /// settled leaves the payer charged with nothing delivered, so check both BEFORE settling:
    /// grantsReady(), and that the content id has no '|'. A TTL above MAX_GRANT_TTL_NS (7 days)
    /// is capped to it.
    public func issueGrant(
      contentRef : Types.ContentRef,
      grantee : Principal,
      receiptId : Text,
      ttlNanos : Int,
    ) : Types.AccessGrant {
      // M-1: Descriptive trap instead of bare assert
      if (not hmacSeedInitialized) {
        Debug.trap("ic402: issueGrant() called before HMAC seed initialized. Ensure startTimers() was called after deployment.");
      };
      if (not grantFieldOk(contentRef.id)) {
        Debug.trap("ic402: issueGrant() refuses a content id containing '|' (the grant HMAC joins its fields with '|'). Check content ids before settling.");
      };
      grantCounter += 1;
      let grantId = "grant-" # Nat.toText(grantCounter);
      let now = Time.now();
      let expiresAt = now + Int.min(ttlNanos, MAX_GRANT_TTL_NS);
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
    /// H-8 (v2): `caller` MUST equal grant.grantee. Grants are non-transferable —
    /// the grantee binding in the HMAC is now enforced against the actual caller,
    /// so a leaked grant blob cannot be replayed by a third party.
    public func verifyGrant(caller : Principal, grant : Types.AccessGrant) : Types.AccessGrantResult {
      if (not Principal.equal(caller, grant.grantee)) {
        return #invalidGrant("Caller is not the grantee of grant " # grant.grantId);
      };
      // 2.22.0: issueGrant never puts '|' in either field, so a grant with one is a re-split.
      if (not grantFieldOk(grant.grantId) or not grantFieldOk(grant.contentRef.id)) {
        return #invalidGrant("Grant " # grant.grantId # " has a '|' in its id or content id");
      };

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
          revokedGrants.put(grantId, Time.now());
          true;
        };
      };
    };

    /// M-1: Remove revoked grants older than 7 days to prevent unbounded growth.
    /// Call from a recurring timer (e.g., hourly via Gateway.startTimers). 2.22.0: issueGrant caps
    /// a grant's lifetime at the same 7 days, so a revocation outlives the grant it revokes.
    public func gcRevokedGrants() { ignore gcRevokedGrantsUpTo(revokedGrants.size()) };

    /// gcRevokedGrants, removing at most `limit` stale entries. `more` is true when stale entries
    /// remain because the limit stopped it. No trap path (2.19.0, for Gateway.runMaintenance).
    public func gcRevokedGrantsUpTo(limit : Nat) : { removed : Nat; more : Bool } {
      let cutoff = Time.now() - MAX_GRANT_TTL_NS; // 7 days
      // Collect first, then delete: a HashMap must not change while it is being iterated.
      let ids = Buffer.Buffer<Text>(0);
      var more = false;
      label scan for ((id, timestamp) in revokedGrants.entries()) {
        if (timestamp < cutoff) {
          if (ids.size() == limit) { more := true; break scan };
          ids.add(id);
        };
      };
      for (id in ids.vals()) { revokedGrants.delete(id) };
      { removed = ids.size(); more };
    };

    // ── Stable state ──

    /// Serialize grant state for stable storage.
    public func toStable() : Types.StableAccessGrantState {
      {
        revokedGrantIds = Iter.toArray(
          Iter.map<(Text, Int), Text>(
            revokedGrants.entries(),
            func((id, _)) { id },
          )
        );
        revokedGrantTimestamps = ?Iter.toArray(revokedGrants.entries());
        grantCounter;
        hmacSeed;
      };
    };

    /// Restore grant state from stable storage.
    public func loadStable(data : Types.StableAccessGrantState) {
      grantCounter := data.grantCounter;
      hmacSeed := data.hmacSeed;
      hmacSeedInitialized := (hmacSeed > 0);
      // M-1: Prefer timestamped entries; fall back to legacy revokedGrantIds (timestamp = now).
      switch (data.revokedGrantTimestamps) {
        case (?entries) {
          revokedGrants := HashMap.HashMap<Text, Int>(
            entries.size(), Text.equal, Text.hash,
          );
          for ((id, ts) in entries.values()) {
            revokedGrants.put(id, ts);
          };
        };
        case (null) {
          let now = Time.now();
          revokedGrants := HashMap.HashMap<Text, Int>(
            data.revokedGrantIds.size(), Text.equal, Text.hash,
          );
          for (id in data.revokedGrantIds.values()) {
            revokedGrants.put(id, now);
          };
        };
      };
    };
  };
};
