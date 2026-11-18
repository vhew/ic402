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
import Buffer "mo:base/Buffer";
import Principal "mo:base/Principal";
import SHA256 "mo:sha2/Sha256";
import Utils "Utils";

module {

  let MAX_NONCES : Nat = 10_000;

  /// 2.21.0: how long past its expiry the clean-up keeps a nonce that holds a stored pending
  /// transfer: the ledger's 24-hour deduplication window, its 60 s permitted drift, and a margin.
  /// Until then the payer's re-submit can still be decided by the ledger; after it the ledger
  /// answers #TooOld anyway.
  public let PENDING_RETENTION_NS : Int = 86_700_000_000_000; // (24 h + 5 min) in nanoseconds

  /// 2.21.0: the exact ICRC-2 transfer a pending ICP charge sent (Gateway.setLedgerDedup), kept so
  /// a re-submit of the same payment can send it again and let the ledger's deduplication decide.
  public type PendingCharge = {
    ledger : Principal;
    network : Text;
    args : Types.TransferFromArg;
  };

  /// Deterministic nonce generator with lock/consume/unlock replay protection.
  public class NonceManager(canisterPrincipal : Principal) {

    var counter : Nat = 0;
    // nonce -> (expiry, bound amount, network, token)
    var nonces = HashMap.HashMap<Blob, (Int, Nat, Text, Text)>(64, Blob.equal, Blob.hash);
    // C-1: nonces currently locked for settlement (persisted across upgrades)
    var locked = HashMap.HashMap<Blob, Bool>(16, Blob.equal, Blob.hash);
    // M-5: insertion-order ring for bounded eviction (transient — rebuilt on load).
    var insertionOrder = Buffer.Buffer<Blob>(64);

    /// Generate a deterministic nonce bound to a specific payment context.
    /// nonce = sha256(canisterPrincipal ++ counter)
    public func generate(expiry : Int, amount : Nat, network : Text, token : Text) : Blob {
      let counterBytes = Utils.natToBytes8(counter);
      let principalBytes = Blob.toArray(Principal.toBlob(canisterPrincipal));
      let input = Array.append(principalBytes, counterBytes);
      let nonce = SHA256.fromArray(#sha256, input);
      counter += 1;

      // M-5: Enforce a HARD cap (not just a GC trigger). First drop expired
      // entries; if still at capacity, evict the OLDEST unlocked nonce. Locked
      // (in-flight settlement) nonces are never evicted, so replay protection on
      // active settlements is preserved. Under sustained 402-challenge spam this
      // bounds memory at ~MAX_NONCES instead of growing without limit.
      //
      // The `insertionOrder` size trigger is essential: consumeLocked()/unlock()
      // remove a nonce from `nonces` but not from the ring, so on settle-heavy
      // traffic `nonces` stays small and the MAX_NONCES branch never fires. Firing
      // gcExpired() once the ring reaches 2*MAX_NONCES compacts it back down to the
      // live set, bounding the ring (it would otherwise leak one blob per payment).
      if (nonces.size() >= MAX_NONCES or insertionOrder.size() >= 2 * MAX_NONCES) {
        gcExpired();
        while (nonces.size() >= MAX_NONCES and evictOldestUnlocked()) {};
      };

      nonces.put(nonce, (expiry, amount, network, token));
      insertionOrder.add(nonce);
      nonce;
    };

    // 2.21.0: the transfer of each pending ICP charge, by nonce (Gateway.setLedgerDedup). Transient:
    // after an upgrade a pending charge answers #settlementPending, as in 2.20.0. An entry never
    // outlives its nonce's lock: setPending requires the lock, and consumeLocked, unlock and
    // gcExpired delete the entry with it.
    var pending = HashMap.HashMap<Blob, PendingCharge>(4, Blob.equal, Blob.hash);

    /// 2.21.0: remember the transfer of a charge whose outcome is unknown. Ignored unless the nonce
    /// is locked.
    public func setPending(nonce : Blob, charge : PendingCharge) {
      if (locked.get(nonce) != null) pending.put(nonce, charge);
    };

    /// 2.21.0: remove and return the pending transfer for `nonce`. The caller removes it BEFORE it
    /// re-sends the transfer, so a second re-submit arriving meanwhile finds none and sends nothing.
    public func takePending(nonce : Blob) : ?PendingCharge { pending.remove(nonce) };

    // M-5: Evict the oldest unlocked nonce. Returns false if none can be evicted
    // (all remaining are locked — bounded by concurrent in-flight settlements).
    func evictOldestUnlocked() : Bool {
      var i = 0;
      while (i < insertionOrder.size()) {
        let n = insertionOrder.get(i);
        switch (nonces.get(n)) {
          case (null) {
            // Stale order entry (already consumed/expired) — drop and keep scanning.
            ignore insertionOrder.remove(i);
          };
          case (?_) {
            switch (locked.get(n)) {
              case (?_) { i += 1 }; // locked: skip, try the next oldest
              case (null) {
                nonces.delete(n);
                ignore insertionOrder.remove(i);
                return true;
              };
            };
          };
        };
      };
      false;
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
      pending.delete(nonce);
    };

    /// Unlock a nonce (call after failed settlement, allowing client retry).
    public func unlock(nonce : Blob) {
      locked.delete(nonce);
      pending.delete(nonce);
    };

    /// 2.20.0: whether a nonce is locked, i.e. a settlement with it is in flight or ended with an
    /// unknown outcome (#settlementPending). Lets settle tell "do not pay again" apart from
    /// "expired, pay with a fresh nonce".
    public func isLocked(nonce : Blob) : Bool { locked.get(nonce) != null };

    /// Check if a nonce exists and is valid (without consuming or locking).
    public func exists(nonce : Blob) : Bool {
      switch (nonces.get(nonce)) {
        case (null) { false };
        case (?(expiry, _, _, _)) { Time.now() <= expiry };
      };
    };

    /// Remove expired nonces and their locks. 2.21.0: a nonce holding a stored pending transfer is
    /// kept until PENDING_RETENTION_NS past its expiry. Only an authenticated payer's charge whose
    /// transfer, sent after a successful fee query, was rejected with an unknown outcome can store
    /// one (Gateway.settleFrom), so a caller cannot create them at will to fill the table.
    public func gcExpired() {
      let now = Time.now();
      let toRemove = Iter.toArray(
        Iter.filter<(Blob, (Int, Nat, Text, Text))>(
          nonces.entries(),
          func((nonce, (expiry, _, _, _))) {
            if (pending.get(nonce) != null) { now > expiry + PENDING_RETENTION_NS } else { now > expiry };
          },
        )
      );
      for ((nonce, _) in toRemove.values()) {
        nonces.delete(nonce);
        locked.delete(nonce);
        pending.delete(nonce);
      };
      // M-5: Compact the insertion-order ring so it tracks only live nonces.
      let compacted = Buffer.Buffer<Blob>(nonces.size());
      for (n in insertionOrder.vals()) {
        switch (nonces.get(n)) { case (?_) { compacted.add(n) }; case (null) {} };
      };
      insertionOrder := compacted;
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
        data.nonces.values(), data.nonces.size(), Blob.equal, Blob.hash,
      );
      counter := data.counter;
      // M-5: Rebuild the (transient) insertion-order ring from restored nonces.
      // Order is approximate after an upgrade, which only affects eviction order.
      insertionOrder := Buffer.Buffer<Blob>(nonces.size());
      for ((nonce, _) in nonces.entries()) { insertionOrder.add(nonce) };
      pending := HashMap.HashMap<Blob, PendingCharge>(4, Blob.equal, Blob.hash); // transient
      // C-1: Restore locked nonces if present
      switch (data.lockedNonces) {
        case (?locks) {
          locked := HashMap.HashMap<Blob, Bool>(locks.size(), Blob.equal, Blob.hash);
          for (nonce in locks.values()) {
            locked.put(nonce, true);
          };
        };
        case (null) {};
      };
    };
  };
};
