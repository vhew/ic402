/// agentflow — Deterministic nonce generation and replay protection.
import Types "Types";
import HashMap "mo:base/HashMap";
import Blob "mo:base/Blob";
import Nat "mo:base/Nat";
import Nat8 "mo:base/Nat8";
import Time "mo:base/Time";
import Iter "mo:base/Iter";
import Array "mo:base/Array";
import Principal "mo:base/Principal";
import SHA256 "mo:sha2/Sha256";

module {

  let MAX_NONCES : Nat = 10_000;

  public class NonceManager(canisterPrincipal : Principal) {

    var counter : Nat = 0;
    // nonce -> expiry timestamp
    var nonces = HashMap.HashMap<Blob, Int>(64, Blob.equal, Blob.hash);

    /// Generate a deterministic nonce via sha256(canisterPrincipal ++ counter).
    public func generate(expiry : Int) : Blob {
      let counterBytes = natToBytes(counter);
      let principalBytes = Blob.toArray(Principal.toBlob(canisterPrincipal));
      let input = Array.append(principalBytes, counterBytes);
      let nonce = SHA256.fromArray(#sha256, input);
      counter += 1;

      // Enforce bounded set — GC expired before adding
      if (nonces.size() >= MAX_NONCES) {
        gcExpired();
      };

      nonces.put(nonce, expiry);
      nonce;
    };

    /// Consume a nonce: returns true if valid and not expired, removes it.
    public func consume(nonce : Blob) : Bool {
      switch (nonces.get(nonce)) {
        case (null) { false };
        case (?expiry) {
          if (Time.now() > expiry) {
            nonces.delete(nonce);
            false;
          } else {
            nonces.delete(nonce);
            true;
          };
        };
      };
    };

    /// Check if a nonce exists (without consuming).
    public func exists(nonce : Blob) : Bool {
      switch (nonces.get(nonce)) {
        case (null) { false };
        case (?expiry) { Time.now() <= expiry };
      };
    };

    /// Remove expired nonces.
    public func gcExpired() {
      let now = Time.now();
      let toRemove = Iter.toArray(
        Iter.filter<(Blob, Int)>(
          nonces.entries(),
          func((_, expiry)) { now > expiry },
        )
      );
      for ((nonce, _) in toRemove.vals()) {
        nonces.delete(nonce);
      };
    };

    public func toStable() : Types.StableNonceState {
      {
        nonces = Iter.toArray(nonces.entries());
        counter;
      };
    };

    public func loadStable(data : Types.StableNonceState) {
      nonces := HashMap.fromIter<Blob, Int>(
        data.nonces.vals(), data.nonces.size(), Blob.equal, Blob.hash,
      );
      counter := data.counter;
    };
  };

  // Convert Nat to big-endian bytes (8 bytes)
  func natToBytes(n : Nat) : [Nat8] {
    var value = n;
    let bytes = Array.init<Nat8>(8, 0);
    var i = 7 : Nat;
    while (i > 0) {
      bytes[i] := Nat8.fromNat(value % 256);
      value := value / 256;
      i -= 1;
    };
    bytes[0] := Nat8.fromNat(value % 256);
    Array.freeze(bytes);
  };
};
