/// ic402 — Deterministic nonce generation and replay protection.
///
/// Each nonce is bound to a payment amount at generation time.
/// Settlement uses a lock/consume/unlock pattern to prevent
/// nonce waste on failed payments while blocking double-spend.
import Types "Types";
import HashMap "mo:base/HashMap";
import Blob "mo:base/Blob";
import Nat "mo:base/Nat";
import Time "mo:base/Time";
import Iter "mo:base/Iter";
import Array "mo:base/Array";
import Principal "mo:base/Principal";
import SHA256 "mo:sha2/Sha256";
import Utils "Utils";

module {

  let MAX_NONCES : Nat = 10_000;

  public class NonceManager(canisterPrincipal : Principal) {

    var counter : Nat = 0;
    // nonce -> (expiry, bound amount)
    var nonces = HashMap.HashMap<Blob, (Int, Nat)>(64, Blob.equal, Blob.hash);
    // nonces currently locked for settlement (transient, not persisted)
    let locked = HashMap.HashMap<Blob, Bool>(16, Blob.equal, Blob.hash);

    /// Generate a deterministic nonce bound to a specific payment amount.
    /// nonce = sha256(canisterPrincipal ++ counter)
    public func generate(expiry : Int, amount : Nat) : Blob {
      let counterBytes = Utils.natToBytes8(counter);
      let principalBytes = Blob.toArray(Principal.toBlob(canisterPrincipal));
      let input = Array.append(principalBytes, counterBytes);
      let nonce = SHA256.fromArray(#sha256, input);
      counter += 1;

      if (nonces.size() >= MAX_NONCES) {
        gcExpired();
      };

      nonces.put(nonce, (expiry, amount));
      nonce;
    };

    /// Lock a nonce for settlement. Returns the bound amount if valid,
    /// not expired, and not already locked. The nonce stays in the map
    /// but cannot be locked again until unlocked or consumed.
    public func lock(nonce : Blob) : ?Nat {
      switch (locked.get(nonce)) {
        case (?_) { return null }; // already in use
        case (null) {};
      };
      switch (nonces.get(nonce)) {
        case (null) { null };
        case (?(expiry, amount)) {
          if (Time.now() > expiry) {
            nonces.delete(nonce);
            null;
          } else {
            locked.put(nonce, true);
            ?amount;
          };
        };
      };
    };

    /// Permanently consume a locked nonce (call after successful settlement).
    public func consumeLocked(nonce : Blob) {
      nonces.delete(nonce);
      locked.delete(nonce);
    };

    /// Unlock a nonce (call after failed settlement, allowing client retry).
    public func unlock(nonce : Blob) {
      locked.delete(nonce);
    };

    /// Check if a nonce exists and is valid (without consuming or locking).
    public func exists(nonce : Blob) : Bool {
      switch (nonces.get(nonce)) {
        case (null) { false };
        case (?(expiry, _)) { Time.now() <= expiry };
      };
    };

    /// Remove expired nonces and their locks.
    public func gcExpired() {
      let now = Time.now();
      let toRemove = Iter.toArray(
        Iter.filter<(Blob, (Int, Nat))>(
          nonces.entries(),
          func((_, (expiry, _))) { now > expiry },
        )
      );
      for ((nonce, _) in toRemove.vals()) {
        nonces.delete(nonce);
        locked.delete(nonce);
      };
    };

    public func toStable() : Types.StableNonceState {
      {
        nonces = Iter.toArray(nonces.entries());
        counter;
      };
    };

    public func loadStable(data : Types.StableNonceState) {
      nonces := HashMap.fromIter<Blob, (Int, Nat)>(
        data.nonces.vals(), data.nonces.size(), Blob.equal, Blob.hash,
      );
      counter := data.counter;
      // locked is transient — fresh on every upgrade
    };
  };
};
