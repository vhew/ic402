/// ic402 — Session subsystem (escrow deposits, cumulative vouchers, lifecycle).
import Types "Types";
import Policy "Policy";
import Escrow "Escrow";
import Time "mo:base/Time";
import Nat "mo:base/Nat";
import Nat64 "mo:base/Nat64";
import Text "mo:base/Text";
import HashMap "mo:base/HashMap";
import Iter "mo:base/Iter";
import Array "mo:base/Array";
import Principal "mo:base/Principal";
import Blob "mo:base/Blob";
import CBOR "mo:cbor";
import Ed25519 "mo:ed25519";

module {

  /// Encode a voucher payload as CBOR for Ed25519 signature verification.
  /// Must match the client-side encodeVoucherPayload() exactly:
  /// CBOR array(3): [text(sessionId), uint(cumulativeAmount), uint(sequence)]
  public func encodeVoucherPayload(sessionId : Text, cumulativeAmount : Nat, sequence : Nat) : [Nat8] {
    let value : CBOR.Value = #majorType4([
      #majorType3(sessionId),
      #majorType0(Nat64.fromNat(cumulativeAmount)),
      #majorType0(Nat64.fromNat(sequence)),
    ]);
    switch (CBOR.toBytes(value)) {
      case (#ok(bytes)) { bytes };
      case (#err(_)) { assert false; [] };
    };
  };

  public class Sessions(
    canisterPrincipal : Principal,
    config : Types.Config,
    policy : Policy.Engine,
    escrowManager : Escrow.EscrowManager,
  ) {

    var sessions = HashMap.HashMap<Text, Types.InternalSessionState>(16, Text.equal, Text.hash);
    var sessionCounter : Nat = 0;
    // Per-caller lock to prevent concurrent openSession TOCTOU.
    // Stores timestamp so stale locks (from failed async calls) auto-expire after 5 minutes.
    let sessionOpenLocks = HashMap.HashMap<Principal, Int>(8, Principal.equal, Principal.hash);

    func findLedger(tokenPrincipalText : Text) : ?Types.TokenConfig {
      for (t in config.tokens.vals()) {
        if (Principal.toText(t.ledger) == tokenPrincipalText) return ?t;
      };
      null;
    };

    func recipientText() : Text {
      switch (config.recipient.subaccount) {
        case (null) { Principal.toText(config.recipient.owner) };
        case (?_) { Principal.toText(config.recipient.owner) };
      };
    };

    func recipientAccount() : Types.Account {
      { owner = config.recipient.owner; subaccount = config.recipient.subaccount };
    };

    /// Count active (open) sessions for a caller.
    func activeSessionCount(caller : Principal) : Nat {
      var count = 0;
      for ((_, s) in sessions.entries()) {
        if (Principal.equal(s.payer, caller) and s.status == #open) {
          count += 1;
        };
      };
      count;
    };

    /// Convert internal session to public SessionState.
    func toPublic(s : Types.InternalSessionState) : Types.SessionState {
      {
        id = s.id;
        payer = s.payer;
        deposited = s.deposited;
        consumed = s.consumed;
        remaining = s.remaining;
        voucherCount = s.voucherCount;
        status = s.status;
        openedAt = s.openedAt;
        lastActivityAt = s.lastActivityAt;
      };
    };

    /// Generate the next session ID. Uses and increments the session counter.
    public func nextSessionId() : Text {
      sessionCounter += 1;
      "sess-" # Nat.toText(sessionCounter);
    };

    /// Set the session counter (used when restoring from Gateway's receiptCounter).
    public func setCounter(c : Nat) {
      sessionCounter := c;
    };

    /// Get the current session counter value.
    public func getCounter() : Nat {
      sessionCounter;
    };

    /// Generate a session offer for 402 response.
    /// Validates and returns the intent. The intent's expiry is enforced
    /// by openSession — expired intents are rejected.
    public func offerSession(intent : Types.SessionIntent) : Types.SessionIntent {
      // Validate intent fields
      assert(intent.suggestedDeposit > 0);
      intent;
    };

    /// Open a session with ICRC-2 escrow deposit.
    public func openSession(
      caller : Principal,
      intent : Types.SessionIntent,
      clientConfig : Types.SessionConfig,
      sig : Types.PaymentSignature,
    ) : async { #ok : Types.SessionState; #err : Types.PaymentResult } {
      // Calculate deposit: min(suggestedDeposit, maxDeposit)
      let deposit = Nat.min(intent.suggestedDeposit, clientConfig.maxDeposit);

      // Check minimum deposit
      switch (intent.minDeposit) {
        case (?min) {
          if (deposit < min) { sessionOpenLocks.delete(caller); return #err(#depositBelowMinimum(min)) };
        };
        case (null) {};
      };

      // Prevent concurrent openSession calls for the same caller (TOCTOU protection).
      // Locks auto-expire after 5 minutes to prevent permanent deadlock from failed async.
      let lockTimeout = 300_000_000_000; // 5 minutes in nanoseconds
      switch (sessionOpenLocks.get(caller)) {
        case (?lockTime) {
          if (Time.now() - lockTime < lockTimeout) {
            return #err(#policyDenied("Session open already in progress"));
          };
          // Stale lock — expired, allow override
        };
        case (null) {};
      };
      sessionOpenLocks.put(caller, Time.now());

      // Check policy
      let activeCount = activeSessionCount(caller);
      switch (policy.checkSessionOpen(caller, deposit, activeCount)) {
        case (#denied(r)) { sessionOpenLocks.delete(caller); return #err(#policyDenied(r)) };
        case (#ok) {};
      };

      // Generate session ID and escrow subaccount
      let sessionId = nextSessionId();
      let subaccount = escrowManager.deriveSubaccount(sessionId);

      // Find ledger
      let tokenConfig = switch (findLedger(intent.token)) {
        case (?tc) { tc };
        case (null) {
          switch (config.tokens.size()) {
            case (0) { sessionOpenLocks.delete(caller); return #err(#tokenNotAccepted) };
            case (_) { config.tokens[0] };
          };
        };
      };

      let ledger : Types.LedgerActor = actor (Principal.toText(tokenConfig.ledger));

      // Execute deposit via escrow
      let depositResult = await escrowManager.deposit(
        ledger,
        { owner = caller; subaccount = null },
        deposit,
        subaccount,
      );

      switch (depositResult) {
        case (#err(msg)) { sessionOpenLocks.delete(caller); return #err(#settlementFailed(msg)) };
        case (#ok(_)) {};
      };

      // TOCTOU: re-check session count after async deposit
      let activeCountAfter = activeSessionCount(caller);
      let effectivePolicy = policy.getEffectivePolicy(caller);
      switch (effectivePolicy.maxConcurrentSessions) {
        case (?max) {
          if (activeCountAfter >= max) {
            // Refund the deposit
            // Best-effort refund — if this fails, deposit is locked in escrow.
            // Use recoverEscrow() to manually retrieve locked funds.
            let _refundResult = await escrowManager.refund(
              ledger, subaccount,
              { owner = caller; subaccount = null },
              deposit,
            );
            sessionOpenLocks.delete(caller);
            return #err(#policyDenied("Concurrent session limit reached (TOCTOU)"));
          };
        };
        case (null) {};
      };

      // Validate payer's Ed25519 public key (passed in sig.signature)
      if (Blob.toArray(sig.signature).size() != 32) {
        // Refund the deposit since we already transferred
        let _refundResult = await escrowManager.refund(ledger, subaccount, { owner = caller; subaccount = null }, deposit);
        sessionOpenLocks.delete(caller);
        return #err(#invalidSignature);
      };

      let now = Time.now();
      let session : Types.InternalSessionState = {
        id = sessionId;
        payer = caller;
        payerPublicKey = sig.signature; // Must be the payer's 32-byte Ed25519 public key
        deposited = deposit;
        var consumed = 0;
        var remaining = deposit;
        var voucherCount = 0;
        var status = #open;
        openedAt = now;
        var lastActivityAt = now;
        var lastSequence = 0;
        var lastCumulativeAmount = 0;
        subaccount;
        network = intent.network;
        token = intent.token;
        recipient = intent.recipient;
        autoClose = clientConfig.autoClose;
        maxDuration = effectivePolicy.maxSessionDuration;
        idleTimeout = switch (clientConfig.idleTimeout) {
          case (?t) { ?t };
          case (null) { effectivePolicy.sessionIdleTimeout };
        };
      };

      sessions.put(sessionId, session);
      policy.recordSpend(caller, deposit);
      sessionOpenLocks.delete(caller);

      #ok(toPublic(session));
    };

    /// Verify a cumulative voucher and return the delta.
    public func consumeVoucher(voucher : Types.Voucher) : Types.VoucherResult {
      let session = switch (sessions.get(voucher.sessionId)) {
        case (null) { return #sessionNotOpen };
        case (?s) { s };
      };

      // Check session is open
      if (session.status != #open) return #sessionNotOpen;

      // Check sequence monotonicity
      if (voucher.sequence <= session.lastSequence) return #invalidSequence;

      // Check cumulative amount is monotonically increasing
      if (voucher.cumulativeAmount < session.lastCumulativeAmount) return #invalidSequence;

      // Check cumulative doesn't exceed deposit
      if (voucher.cumulativeAmount > session.deposited) return #insufficientDeposit;

      // Compute delta (safe: cumulativeAmount >= lastCumulativeAmount checked above)
      let delta : Nat = voucher.cumulativeAmount - session.lastCumulativeAmount;

      // Check policy
      switch (policy.checkVoucher(session.payer, delta)) {
        case (#denied(r)) { return #policyDenied(r) };
        case (#ok) {};
      };

      // Ed25519 signature verification
      let payload = encodeVoucherPayload(voucher.sessionId, voucher.cumulativeAmount, voucher.sequence);
      let sigBytes = Blob.toArray(voucher.signature);
      let pubKeyBytes = Blob.toArray(session.payerPublicKey);

      if (sigBytes.size() != 64) { return #invalidSignature };
      if (pubKeyBytes.size() != 32) { return #invalidSignature };

      if (not Ed25519.ED25519.verify(sigBytes, payload, pubKeyBytes)) {
        return #invalidSignature;
      };

      // Update session state
      session.consumed := voucher.cumulativeAmount;
      session.remaining := session.deposited - voucher.cumulativeAmount;
      session.voucherCount += 1;
      session.lastSequence := voucher.sequence;
      session.lastCumulativeAmount := voucher.cumulativeAmount;
      session.lastActivityAt := Time.now();

      policy.recordSpend(session.payer, delta);

      #ok(delta);
    };

    /// Get a session's public state.
    public func getSession(sessionId : Text) : ?Types.SessionState {
      switch (sessions.get(sessionId)) {
        case (null) { null };
        case (?s) { ?toPublic(s) };
      };
    };

    /// Close a session: settle consumed, refund remainder.
    public func closeSession(sessionId : Text) : async Types.PaymentResult {
      let session = switch (sessions.get(sessionId)) {
        case (null) { return #settlementFailed("Session not found") };
        case (?s) { s };
      };

      if (session.status == #closed or session.status == #closing) {
        return #settlementFailed("Session already closed");
      };

      session.status := #closing;

      // Find ledger
      let tokenConfig = switch (findLedger(session.token)) {
        case (?tc) { tc };
        case (null) {
          switch (config.tokens.size()) {
            case (0) { return #settlementFailed("No token configured") };
            case (_) { config.tokens[0] };
          };
        };
      };

      let ledger : Types.LedgerActor = actor (Principal.toText(tokenConfig.ledger));

      // Settle consumed amount to recipient
      if (session.consumed > 0) {
        let settleResult = await escrowManager.settle(
          ledger,
          session.subaccount,
          recipientAccount(),
          session.consumed,
        );
        switch (settleResult) {
          case (#err(msg)) {
            session.status := #open; // Revert on failure
            return #settlementFailed("Settle: " # msg);
          };
          case (#ok(_)) {};
        };
      };

      // Refund remainder to payer.
      // The escrow balance after settlement is:
      //   deposited - consumed - settleFee (if consumed > 0)
      // The refund transfer itself costs another fee.
      // So the max refundable amount is: escrowBalance - refundFee
      // Query the actual ledger fee instead of hardcoding
      let fee : Nat = try { await ledger.icrc1_fee() } catch (_) { 10_000 };

      // Guard: consumed must never exceed deposited
      if (session.consumed > session.deposited) {
        session.status := #closed;
        return #settlementFailed("Invariant violation: consumed > deposited");
      };

      let settleFees = if (session.consumed > 0) { fee } else { 0 };
      let escrowBalance = if (session.deposited >= session.consumed + settleFees) {
        session.deposited - session.consumed - settleFees;
      } else { 0 };
      let refunded = if (escrowBalance > fee) { escrowBalance - fee } else { 0 };
      if (refunded > 0) {
        let refundResult = await escrowManager.refund(
          ledger,
          session.subaccount,
          { owner = session.payer; subaccount = null },
          refunded,
        );
        switch (refundResult) {
          case (#err(msg)) {
            // Settlement succeeded but refund failed — mark closed anyway
            session.status := #closed;
            return #settlementFailed("Refund: " # msg);
          };
          case (#ok(_)) {};
        };
      };

      session.status := #closed;

      #ok({
        id = "rcpt-close"; // Placeholder — Gateway provides real receipt ID
        amount = session.consumed;
        token = session.token;
        sender = Principal.toText(session.payer);
        recipient = session.recipient;
        network = session.network;
        timestamp = Time.now();
        txHash = null;
        sessionId = ?session.id;
        refunded = ?refunded;
      });
    };

    /// Close all expired or idle sessions.
    public func closeExpiredSessions() : async [Types.PaymentResult] {
      let now = Time.now();
      let buf = Iter.toArray(
        Iter.filter<(Text, Types.InternalSessionState)>(
          sessions.entries(),
          func((_, s)) {
            if (s.status != #open) return false;

            // Check max duration
            switch (s.maxDuration) {
              case (?maxDur) {
                if (now - s.openedAt > maxDur) return true;
              };
              case (null) {};
            };

            // Check idle timeout
            switch (s.idleTimeout) {
              case (?timeout) {
                if (now - s.lastActivityAt > timeout) return true;
              };
              case (null) {};
            };

            false;
          },
        )
      );

      let resultBuf = Array.init<Types.PaymentResult>(buf.size(), #expired);
      var i = 0;
      for ((sessionId, session) in buf.vals()) {
        session.status := #expired;
        let result = await closeSession(sessionId);
        resultBuf[i] := result;
        i += 1;
      };
      Array.freeze(resultBuf);
    };

    /// Recover funds from an escrow subaccount (admin use only).
    /// Use when a refund failed during openSession and deposit is locked.
    public func recoverEscrow(
      ledger : Types.LedgerActor,
      sessionId : Text,
      recipient : Types.Account,
      amount : Nat,
    ) : async { #ok : Nat; #err : Text } {
      let subaccount = escrowManager.deriveSubaccount(sessionId);
      await escrowManager.refund(ledger, subaccount, recipient, amount);
    };

    // ── Stable state ──

    public func toStable() : [Types.StableSession] {
      Iter.toArray(
        Iter.map<(Text, Types.InternalSessionState), Types.StableSession>(
          sessions.entries(),
          func((_, s)) : Types.StableSession {
            {
              id = s.id;
              payer = s.payer;
              payerPublicKey = s.payerPublicKey;
              deposited = s.deposited;
              consumed = s.consumed;
              remaining = s.remaining;
              voucherCount = s.voucherCount;
              status = s.status;
              openedAt = s.openedAt;
              lastActivityAt = s.lastActivityAt;
              lastSequence = s.lastSequence;
              lastCumulativeAmount = s.lastCumulativeAmount;
              subaccount = s.subaccount;
              network = s.network;
              token = s.token;
              recipient = s.recipient;
              autoClose = s.autoClose;
              maxDuration = s.maxDuration;
              idleTimeout = s.idleTimeout;
            };
          },
        )
      );
    };

    public func loadStable(data : [Types.StableSession]) {
      sessions := HashMap.HashMap<Text, Types.InternalSessionState>(
        data.size(), Text.equal, Text.hash,
      );
      for (ss in data.vals()) {
        let session : Types.InternalSessionState = {
          id = ss.id;
          payer = ss.payer;
          payerPublicKey = ss.payerPublicKey;
          deposited = ss.deposited;
          var consumed = ss.consumed;
          var remaining = ss.remaining;
          var voucherCount = ss.voucherCount;
          var status = ss.status;
          openedAt = ss.openedAt;
          var lastActivityAt = ss.lastActivityAt;
          var lastSequence = ss.lastSequence;
          var lastCumulativeAmount = ss.lastCumulativeAmount;
          subaccount = ss.subaccount;
          network = ss.network;
          token = ss.token;
          recipient = ss.recipient;
          autoClose = ss.autoClose;
          maxDuration = ss.maxDuration;
          idleTimeout = ss.idleTimeout;
        };
        sessions.put(ss.id, session);
      };
    };
  };
};
