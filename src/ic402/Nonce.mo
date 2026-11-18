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
    // outlives its nonce's lock: storing requires the lock, and consumeLocked, unlock and gcExpired
    // delete the entry with it. While a send of the transfer is in flight the entry stays stored
    // (so the clean-up keeps the nonce) and is marked in `inFlight` (so nothing else sends it).
    var pending = HashMap.HashMap<Blob, PendingCharge>(4, Blob.equal, Blob.hash);
    var inFlight = HashMap.HashMap<Blob, Bool>(4, Blob.equal, Blob.hash);

    // 2.22.0: locked nonces whose settlement ended with an unknown outcome (#settlementPending).
    // A locked nonce NOT in this set has a settlement in flight. Transient: loadStable marks every
    // restored lock, since no settlement is in flight across an upgrade. A Motoko canister refuses
    // to upgrade while calls it made are outstanding ("canister_pre_upgrade attempted with
    // outstanding message callbacks"), and no continuation survives into the new code, so the
    // attempt that took a restored lock never finishes: its outcome is unknown. Entries leave
    // with the lock.
    var outcomeUnknown = HashMap.HashMap<Blob, Bool>(4, Blob.equal, Blob.hash);

    /// 2.22.0: mark a locked nonce's settlement as ended with an unknown outcome: the attempt
    /// returned #settlementPending and kept the lock. Until then a locked nonce reads as in flight
    /// (outcomeIsUnknown false). Ignored unless the nonce is locked.
    public func markOutcomeUnknown(nonce : Blob) {
      if (locked.get(nonce) != null) { outcomeUnknown.put(nonce, true) };
    };

    /// 2.22.0: whether a locked nonce's settlement ended with an unknown outcome, as opposed to
    /// still being in flight. False for a nonce that is not locked.
    public func outcomeIsUnknown(nonce : Blob) : Bool { outcomeUnknown.get(nonce) != null };

    /// 2.21.0: store a charge's transfer as in flight, before the first attempt's await: the
    /// clean-up keeps the nonce, and takePending refuses it. Ignored unless the nonce is locked.
    public func setInFlight(nonce : Blob, charge : PendingCharge) {
      if (locked.get(nonce) != null) { pending.put(nonce, charge); inFlight.put(nonce, true) };
    };

    /// 2.21.0: store (or put back) the transfer of a charge whose outcome is unknown, available to
    /// takePending. Ignored unless the nonce is locked.
    public func setPending(nonce : Blob, charge : PendingCharge) {
      if (locked.get(nonce) != null) { pending.put(nonce, charge); inFlight.delete(nonce) };
    };

    /// 2.21.0: check out the stored transfer for a re-send: returns it and marks it in flight. A
    /// second re-submit arriving before it is put back (setPending) or dropped gets null and sends
    /// nothing. It stays stored meanwhile, so the clean-up keeps the nonce.
    public func takePending(nonce : Blob) : ?PendingCharge {
      if (inFlight.get(nonce) != null) return null;
      switch (pending.get(nonce)) {
        case (?p) { inFlight.put(nonce, true); ?p };
        case (null) { null };
      };
    };

    /// 2.21.0: drop the stored transfer (re-sending it can no longer decide anything). The nonce
    /// stays locked.
    public func dropPending(nonce : Blob) {
      pending.delete(nonce);
      inFlight.delete(nonce);
    };

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
      inFlight.delete(nonce);
      outcomeUnknown.delete(nonce);
    };

    /// Unlock a nonce (call after failed settlement, allowing client retry).
    public func unlock(nonce : Blob) {
      locked.delete(nonce);
      pending.delete(nonce);
      inFlight.delete(nonce);
      outcomeUnknown.delete(nonce);
    };

    /// 2.20.0: whether a nonce is locked, i.e. a settlement with it is in flight or ended with an
    /// unknown outcome (#settlementPending). Lets settle tell "do not pay again" apart from
    /// "expired, pay with a fresh nonce". 2.22.0: outcomeIsUnknown tells the two apart.
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
    /// 2.22.0: so is a nonce whose settlement is in flight (locked, outcome not marked unknown):
    /// removing its lock during the attempt's awaits (the fee query, the transfer) would make the
    /// attempt's later setInFlight / setPending silent no-ops while the payer is told to re-submit.
    /// Such locks are bounded by the calls outstanding at once; each attempt ends by releasing its
    /// lock or marking it unknown, so they do not pile up.
    public func gcExpired() { gcExpiredAt(Time.now()) };

    /// gcExpired as of `now` (2.22.0; lets a test move the clock).
    public func gcExpiredAt(now : Int) {
      let toRemove = Iter.toArray(
        Iter.filter<(Blob, (Int, Nat, Text, Text))>(
          nonces.entries(),
          func((nonce, (expiry, _, _, _))) {
            let settling = locked.get(nonce) != null and outcomeUnknown.get(nonce) == null;
            if (pending.get(nonce) != null or settling) { now > expiry + PENDING_RETENTION_NS } else {
              now > expiry;
            };
          },
        )
      );
      for ((nonce, _) in toRemove.values()) {
        nonces.delete(nonce);
        locked.delete(nonce);
        pending.delete(nonce);
        inFlight.delete(nonce);
        outcomeUnknown.delete(nonce);
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
      inFlight := HashMap.HashMap<Blob, Bool>(4, Blob.equal, Blob.hash);
      outcomeUnknown := HashMap.HashMap<Blob, Bool>(4, Blob.equal, Blob.hash);
      // C-1: Restore locked nonces if present. 2.22.0: each with an unknown outcome — nothing that
      // took the lock before the upgrade is still in flight (see `outcomeUnknown`).
      switch (data.lockedNonces) {
        case (?locks) {
          locked := HashMap.HashMap<Blob, Bool>(locks.size(), Blob.equal, Blob.hash);
          for (nonce in locks.values()) {
            locked.put(nonce, true);
            outcomeUnknown.put(nonce, true);
          };
        };
        case (null) {};
      };
    };
  };
};
