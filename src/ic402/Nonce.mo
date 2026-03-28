/// ic402 — Deterministic nonce generation and replay protection.
///
/// Each nonce is bound to a payment amount, network, and token at generation time.
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

  /// Deterministic nonce generator with lock/consume/unlock replay protection.
  public class NonceManager(canisterPrincipal : Principal) {

    var counter : Nat = 0;
    // nonce -> (expiry, bound amount, network, token)
    var nonces = HashMap.HashMap<Blob, (Int, Nat, Text, Text)>(64, Blob.equal, Blob.hash);
    // C-1: nonces currently locked for settlement (persisted across upgrades)
    var locked = HashMap.HashMap<Blob, Bool>(16, Blob.equal, Blob.hash);

    /// Generate a deterministic nonce bound to a specific payment context.
    /// nonce = sha256(canisterPrincipal ++ counter)
    public func generate(expiry : Int, amount : Nat, network : Text, token : Text) : Blob {
      let counterBytes = Utils.natToBytes8(counter);
      let principalBytes = Blob.toArray(Principal.toBlob(canisterPrincipal));
      let input = Array.append(principalBytes, counterBytes);
      let nonce = SHA256.fromArray(#sha256, input);
      counter += 1;

      if (nonces.size() >= MAX_NONCES) {
        gcExpired();
      };

      nonces.put(nonce, (expiry, amount, network, token));
      nonce;
    };

    /// Lock a nonce for settlement. Returns the bound amount if valid,
    /// not expired, not already locked, and the network+token match.
    /// The nonce stays in the map but cannot be locked again until unlocked or consumed.
    public func lock(nonce : Blob, network : Text, token : Text) : ?Nat {
      switch (locked.get(nonce)) {
        case (?_) { return null }; // already in use
        case (null) {};
      };
      switch (nonces.get(nonce)) {
        case (null) { null };
        case (?(expiry, amount, boundNetwork, boundToken)) {
          if (Time.now() > expiry) {
            nonces.delete(nonce);
            null;
          } else if (boundNetwork != network or boundToken != token) {
            null; // H-2: network/token mismatch — reject cross-network replay
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
        case (?(expiry, _, _, _)) { Time.now() <= expiry };
      };
    };

    /// Remove expired nonces and their locks.
    public func gcExpired() {
      let now = Time.now();
      let toRemove = Iter.toArray(
        Iter.filter<(Blob, (Int, Nat, Text, Text))>(
          nonces.entries(),
          func((_, (expiry, _, _, _))) { now > expiry },
        )
      );
      for ((nonce, _) in toRemove.vals()) {
        nonces.delete(nonce);
        locked.delete(nonce);
      };
    };

    /// Serialize nonce state for stable storage.
    public func toStable() : Types.StableNonceState {
      {
        nonces = Iter.toArray(nonces.entries());
        counter;
        // C-1: Persist locked nonces across upgrades
        lockedNonces = ?Iter.toArray(
          Iter.map<(Blob, Bool), Blob>(
            locked.entries(),
            func((nonce, _)) { nonce },
          )
        );
      };
    };

    /// Restore nonce state from stable storage.
    public func loadStable(data : Types.StableNonceState) {
      nonces := HashMap.fromIter<Blob, (Int, Nat, Text, Text)>(
        data.nonces.vals(), data.nonces.size(), Blob.equal, Blob.hash,
      );
      counter := data.counter;
      // C-1: Restore locked nonces if present
      switch (data.lockedNonces) {
        case (?locks) {
          locked := HashMap.HashMap<Blob, Bool>(locks.size(), Blob.equal, Blob.hash);
          for (nonce in locks.vals()) {
            locked.put(nonce, true);
          };
        };
        case (null) {};
      };
    };
  };
};
