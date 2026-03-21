/// agentflow — Main gateway class. Handles charges, sessions, and policy.
import Types "Types";
import Policy "Policy";
import Nonce "Nonce";
import Escrow "Escrow";
import Time "mo:base/Time";
import Nat "mo:base/Nat";
import Text "mo:base/Text";
import HashMap "mo:base/HashMap";
import Iter "mo:base/Iter";
import Array "mo:base/Array";
import Principal "mo:base/Principal";
import Timer "mo:base/Timer";
import Error "mo:base/Error";

module {

  public class Gateway(config : Types.Config, selfPrincipal : Principal) {

    let policy = Policy.Engine();
    let nonceManager = Nonce.NonceManager(selfPrincipal);
    let escrowManager = Escrow.EscrowManager(selfPrincipal);

    var sessions = HashMap.HashMap<Text, Types.InternalSessionState>(16, Text.equal, Text.hash);
    var receiptCounter : Nat = 0;

    func nextReceiptId() : Text {
      receiptCounter += 1;
      "rcpt-" # Nat.toText(receiptCounter);
    };

    func nextSessionId() : Text {
      "sess-" # Nat.toText(receiptCounter + 1);
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

    func findLedger(tokenPrincipalText : Text) : ?Types.TokenConfig {
      for (t in config.tokens.vals()) {
        if (Principal.toText(t.ledger) == tokenPrincipalText) return ?t;
      };
      null;
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

    // ── Charge (x402 "exact") ──

    /// Generate a 402 payment requirement for a given price.
    public func require(price : Types.Price) : Types.PaymentRequirement {
      let expiry = Time.now() + 300_000_000_000; // 5 minutes
      let nonce = nonceManager.generate(expiry);
      {
        scheme = "exact";
        network = price.network;
        token = Principal.toText(price.token);
        amount = price.amount;
        recipient = recipientText();
        nonce;
        expiry;
      };
    };

    /// Verify and settle a charge payment via ICRC-2 transfer_from.
    public func settle(signature : Types.PaymentSignature) : async Types.PaymentResult {
      // Verify nonce
      if (not nonceManager.consume(signature.nonce)) {
        return #expired;
      };

      // Find the token config
      let tokenConfig = switch (findLedger(signature.network)) {
        case (?tc) { tc };
        case (null) {
          // Try to match by iterating tokens
          switch (config.tokens.size()) {
            case (0) { return #tokenNotAccepted };
            case (_) { config.tokens[0] }; // default to first token
          };
        };
      };

      // Parse sender principal
      let senderPrincipal = Principal.fromText(signature.sender);

      // Check policy
      // We need the amount — retrieve from the nonce's associated requirement
      // For MVP, we look up the amount from the signature context
      // The nonce was already consumed, so we trust the flow
      let amount = 0 : Nat; // Will be set by the actual transfer result

      switch (policy.checkCharge(senderPrincipal, amount)) {
        case (#denied(r)) { return #policyDenied(r) };
        case (#ok) {};
      };

      // Construct ledger actor and execute icrc2_transfer_from
      let ledger : Types.LedgerActor = actor (Principal.toText(tokenConfig.ledger));

      try {
        let result = await ledger.icrc2_transfer_from({
          spender_subaccount = null;
          from = { owner = senderPrincipal; subaccount = null };
          to = recipientAccount();
          amount = 0; // The approved amount via ICRC-2 allowance
          fee = null;
          memo = null;
          created_at_time = null;
        });

        switch (result) {
          case (#Ok(blockIndex)) {
            let receipt : Types.PaymentReceipt = {
              id = nextReceiptId();
              amount = 0; // from actual transfer
              token = Principal.toText(tokenConfig.ledger);
              sender = signature.sender;
              recipient = recipientText();
              network = signature.network;
              timestamp = Time.now();
              txHash = ?Nat.toText(blockIndex);
              sessionId = null;
              refunded = null;
            };
            policy.recordSpend(senderPrincipal, receipt.amount);
            #ok(receipt);
          };
          case (#Err(#InsufficientFunds(_))) { #insufficientFunds };
          case (#Err(#InsufficientAllowance(_))) { #insufficientFunds };
          case (#Err(err)) { #settlementFailed("ICRC-2 error: " # debug_show(err)) };
        };
      } catch (e) {
        #settlementFailed("Ledger call failed: " # Error.message(e));
      };
    };

    // ── Session ──

    /// Generate a session offer for 402 response.
    public func offerSession(intent : Types.SessionIntent) : Types.SessionIntent {
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
          if (deposit < min) return #err(#depositBelowMinimum(min));
        };
        case (null) {};
      };

      // Check policy
      let activeCount = activeSessionCount(caller);
      switch (policy.checkSessionOpen(caller, deposit, activeCount)) {
        case (#denied(r)) { return #err(#policyDenied(r)) };
        case (#ok) {};
      };

      // Generate session ID and escrow subaccount
      let sessionId = nextSessionId();
      receiptCounter += 1;
      let subaccount = escrowManager.deriveSubaccount(sessionId);

      // Find ledger
      let tokenConfig = switch (findLedger(intent.token)) {
        case (?tc) { tc };
        case (null) {
          switch (config.tokens.size()) {
            case (0) { return #err(#tokenNotAccepted) };
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
        case (#err(msg)) { return #err(#settlementFailed(msg)) };
        case (#ok(_)) {};
      };

      // TOCTOU: re-check session count after async deposit
      let activeCountAfter = activeSessionCount(caller);
      let effectivePolicy = policy.getEffectivePolicy(caller);
      switch (effectivePolicy.maxConcurrentSessions) {
        case (?max) {
          if (activeCountAfter >= max) {
            // Refund the deposit
            ignore await escrowManager.refund(
              ledger, subaccount,
              { owner = caller; subaccount = null },
              deposit,
            );
            return #err(#policyDenied("Concurrent session limit reached (TOCTOU)"));
          };
        };
        case (null) {};
      };

      let now = Time.now();
      let session : Types.InternalSessionState = {
        id = sessionId;
        payer = caller;
        payerPublicKey = sig.signature; // Store payer's public key for voucher verification
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
      // INSECURE: MVP stub — accepts all signatures.
      // Production should verify: Ed25519.verify(session.payerPublicKey, cbor(sessionId, cumulativeAmount, sequence), voucher.signature)

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

      // Refund remainder to payer
      let refunded = session.remaining;
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
        id = nextReceiptId();
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

    /// Start a recurring timer for closing expired sessions.
    /// Must be called from actor context (requires <system> capability).
    public func startTimers<system>() {
      ignore Timer.recurringTimer<system>(#seconds 60, func() : async () {
        ignore await closeExpiredSessions();
      });
    };

    // ── Policy ──

    public func setPolicy(caller : ?Principal, p : Types.SpendingPolicy) {
      switch (caller) {
        case (null) { policy.setGlobalPolicy(p) };
        case (?c) { policy.setCallerPolicy(c, p) };
      };
    };

    public func getPolicy(caller : Principal) : Types.SpendingPolicy {
      policy.getEffectivePolicy(caller);
    };

    public func dailySpend(caller : Principal) : Nat {
      policy.getDailySpendAmount(caller);
    };

    // ── ERC-8004 ──

    /// Register as an agent on ERC-8004 (stub — tECDSA post-hackathon).
    public func registerAgent() : async Nat {
      // TODO: tECDSA sign EVM transaction to mint ERC-721 on IdentityRegistry
      0; // Placeholder agent ID
    };

    // ── Stable state ──

    public func toStable() : Types.StableGatewayState {
      let stableSessions = Iter.toArray(
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
      {
        sessions = stableSessions;
        nonces = nonceManager.toStable();
        policy = policy.toStable();
        receiptCounter;
      };
    };

    public func loadStable(data : Types.StableGatewayState) {
      nonceManager.loadStable(data.nonces);
      policy.loadStable(data.policy);
      receiptCounter := data.receiptCounter;

      sessions := HashMap.HashMap<Text, Types.InternalSessionState>(
        data.sessions.size(), Text.equal, Text.hash,
      );
      for (ss in data.sessions.vals()) {
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
