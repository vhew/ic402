/// ic402 — Session subsystem (escrow deposits, cumulative vouchers, lifecycle).
import Types "Types";
import Policy "Policy";
import Escrow "Escrow";
import EvmEscrow "EvmEscrow";
import EvmSender "EvmSender";
import Utils "Utils";
import EvmUtils "EvmUtils";
import Eip712 "Eip712";
import Time "mo:base/Time";
import Nat "mo:base/Nat";
import Nat64 "mo:base/Nat64";
import Text "mo:base/Text";
import HashMap "mo:base/HashMap";
import Iter "mo:base/Iter";
import Array "mo:base/Array";
import Principal "mo:base/Principal";
import Blob "mo:base/Blob";
import Error "mo:base/Error";
import CBOR "mo:cbor";
import Ed25519 "mo:ed25519";
import Debug "mo:base/Debug";

module {

  /// Encode a voucher payload as CBOR for Ed25519 signature verification.
  /// Must match the client-side encodeVoucherPayload() exactly:
  /// CBOR array(3): [text(sessionId), uint(cumulativeAmount), uint(sequence)]
  /// H-2: Returns null if cumulativeAmount or sequence exceeds Nat64 range.
  public func encodeVoucherPayload(sessionId : Text, cumulativeAmount : Nat, sequence : Nat) : ?[Nat8] {
    // H-2: Bounds check before Nat64 conversion to prevent trap
    let maxNat64 : Nat = 18_446_744_073_709_551_615;
    if (cumulativeAmount > maxNat64 or sequence > maxNat64) { return null };

    let value : CBOR.Value = #majorType4([
      #majorType3(sessionId),
      #majorType0(Nat64.fromNat(cumulativeAmount)),
      #majorType0(Nat64.fromNat(sequence)),
    ]);
    switch (CBOR.toBytes(value)) {
      case (#ok(bytes)) { ?bytes };
      case (#err(_)) { null };
    };
  };

  func isEvmNetwork(network : Text) : Bool {
    Utils.isEvmNetwork(network);
  };

  func extractChainId(network : Text) : ?Nat {
    Utils.extractChainId(network);
  };

  /// Session lifecycle manager: escrow deposits, cumulative vouchers, expiry, and close/refund.
  public class Sessions(
    canisterPrincipal : Principal,
    config : Types.Config,
    policy : Policy.Engine,
    escrowManager : Escrow.EscrowManager,
    evmEscrowManager : EvmEscrow.EvmEscrowManager,
    evmSender : ?EvmSender.EvmSender,
    evmRecipientAddress : { get : () -> ?Text },
  ) {

    var sessions = HashMap.HashMap<Text, Types.InternalSessionState>(16, Text.equal, Text.hash);
    var sessionCounter : Nat = 0;
    // Per-caller lock to prevent concurrent openSession TOCTOU.
    // Stores timestamp so stale locks (from failed async calls) auto-expire after 5 minutes.
    let sessionOpenLocks = HashMap.HashMap<Principal, Int>(8, Principal.equal, Principal.hash);

    func findLedger(identifier : Text) : ?Types.TokenConfig {
      Utils.findLedger(config.tokens, identifier);
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
    /// Validates the intent (deposit > 0, expiry in the future) and returns it.
    public func offerSession(intent : Types.SessionIntent) : Types.SessionIntent {
      if (intent.suggestedDeposit == 0) { Debug.trap("ic402: offerSession() called with suggestedDeposit = 0") };
      if (intent.expiry <= Time.now()) { Debug.trap("ic402: offerSession() called with expired intent") };
      intent;
    };

    /// Open a session. Dispatches to ICRC-2 (ICP) or EVM deposit verification.
    public func openSession(
      caller : Principal,
      intent : Types.SessionIntent,
      clientConfig : Types.SessionConfig,
      sig : Types.PaymentSignature,
    ) : async { #ok : Types.SessionState; #err : Types.PaymentResult } {
      // M-3: Rate-limit session open attempts (uses policy engine's per-caller rate limiter)
      switch (policy.checkCharge(caller, 0)) {
        case (#denied(r)) { return #err(#policyDenied(r)) };
        case (#ok) {};
      };

      // M-2: Check intent expiry before processing
      if (Time.now() > intent.expiry) {
        return #err(#expired("Session intent expired"));
      };

      // Dispatch: EVM or ICP?
      if (isEvmNetwork(intent.network)) {
        return await openEvmSession(caller, intent, clientConfig, sig);
      };

      // ── ICP session via ICRC-2 escrow ──

      // Calculate deposit: min(suggestedDeposit, maxDeposit)
      let deposit = Nat.min(intent.suggestedDeposit, clientConfig.maxDeposit);

      // Check minimum deposit
      switch (intent.minDeposit) {
        case (?min) {
          if (deposit < min) { return #err(#depositBelowMinimum(min)) };
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
            case (0) { sessionOpenLocks.delete(caller); return #err(#tokenNotAccepted("No accepted token configured")) };
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

      // Validate payer's Ed25519 public key
      let sessionPublicKey = switch (sig.publicKey) {
        case (?pk) { pk };
        case (null) {
          let _refundResult = await escrowManager.refund(ledger, subaccount, { owner = caller; subaccount = null }, deposit);
          sessionOpenLocks.delete(caller);
          return #err(#invalidSignature("Missing publicKey in PaymentSignature (required for sessions)"));
        };
      };
      if (Blob.toArray(sessionPublicKey).size() != 32) {
        let _refundResult = await escrowManager.refund(ledger, subaccount, { owner = caller; subaccount = null }, deposit);
        sessionOpenLocks.delete(caller);
        return #err(#invalidSignature("Public key must be 32 bytes (Ed25519)"));
      };

      let now = Time.now();
      let session : Types.InternalSessionState = {
        id = sessionId;
        payer = caller;
        payerPublicKey = sessionPublicKey;
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
        evmDeposit = null; // ICP session
      };

      sessions.put(sessionId, session);
      policy.recordSpend(caller, deposit);
      sessionOpenLocks.delete(caller);

      #ok(toPublic(session));
    };

    // ── EVM session open ──

    /// Open a session with an EVM USDC deposit via EIP-3009.
    /// The client signs a TransferWithAuthorization for the deposit amount.
    /// The canister verifies the EIP-712 signature locally, then executes
    /// the transfer on-chain via tECDSA (canister acts as its own facilitator).
    /// On close, the canister refunds unused deposit via ERC-20 transfer.
    func openEvmSession(
      caller : Principal,
      intent : Types.SessionIntent,
      clientConfig : Types.SessionConfig,
      sig : Types.PaymentSignature,
    ) : async { #ok : Types.SessionState; #err : Types.PaymentResult } {
      // M-3: Rate-limit session open attempts
      switch (policy.checkCharge(caller, 0)) {
        case (#denied(r)) { return #err(#policyDenied(r)) };
        case (#ok) {};
      };

      let deposit = Nat.min(intent.suggestedDeposit, clientConfig.maxDeposit);

      // Check minimum deposit
      switch (intent.minDeposit) {
        case (?min) {
          if (deposit < min) { return #err(#depositBelowMinimum(min)) };
        };
        case (null) {};
      };

      // Acquire lock
      let lockTimeout = 300_000_000_000;
      switch (sessionOpenLocks.get(caller)) {
        case (?lockTime) {
          if (Time.now() - lockTime < lockTimeout) {
            return #err(#policyDenied("Session open already in progress"));
          };
        };
        case (null) {};
      };
      sessionOpenLocks.put(caller, Time.now());

      // Policy check
      let activeCount = activeSessionCount(caller);
      switch (policy.checkSessionOpen(caller, deposit, activeCount)) {
        case (#denied(r)) { sessionOpenLocks.delete(caller); return #err(#policyDenied(r)) };
        case (#ok) {};
      };

      // Require EIP-3009 authorization for EVM session deposits
      let authz = switch (sig.authorization) {
        case (?a) { a };
        case (null) {
          sessionOpenLocks.delete(caller);
          return #err(#invalidSignature("EIP-3009 authorization required for EVM session deposits"));
        };
      };

      // Extract chain ID
      let chainId = switch (extractChainId(intent.network)) {
        case (?id) { id };
        case (null) {
          sessionOpenLocks.delete(caller);
          return #err(#networkNotSupported("Invalid network: " # intent.network));
        };
      };

      // Validate authorization amount
      if (authz.value < deposit) {
        sessionOpenLocks.delete(caller);
        return #err(#depositBelowMinimum(deposit));
      };

      // Verify EIP-712 signature locally before executing on-chain
      // (saves an expensive outcall if the signature is invalid)
      let tokenAddr = intent.token;
      var tokenName : ?Text = null;
      var tokenVersion : ?Text = null;
      // M-5: Look up per-chain token name/version for EIP-712 domain separator.
      // Return error if chain not configured (wrong defaults cause silent sig failure).
      let evmChain : Types.EvmChainConfig = do {
        var found : ?Types.EvmChainConfig = null;
        for (c in config.evmChains.vals()) { if (c.chainId == chainId) found := ?c };
        switch (found) {
          case (?chain) { chain };
          case (null) {
            sessionOpenLocks.delete(caller);
            return #err(#networkNotSupported("No EVM chain config for chainId " # Nat.toText(chainId)));
          };
        };
      };
      if (evmChain.tokens.size() > 0) {
        tokenName := evmChain.tokens[0].name;
        tokenVersion := evmChain.tokens[0].version;
      };
      let verified = Eip712.verifyAuthorization(
        chainId, EvmUtils.hexToBytes(tokenAddr),
        EvmUtils.hexToBytes(authz.from), EvmUtils.hexToBytes(authz.to),
        authz.value, authz.validAfter, authz.validBefore,
        Blob.toArray(authz.nonce), authz.v,
        Blob.toArray(authz.r), Blob.toArray(authz.s),
        tokenName, tokenVersion,
      );
      if (not verified) {
        sessionOpenLocks.delete(caller);
        return #err(#invalidSignature("EIP-3009 authorization signature verification failed"));
      };

      // Execute transferWithAuthorization via tECDSA (canister acts as facilitator)
      let sender = switch (evmSender) {
        case (?s) { s };
        case (null) {
          sessionOpenLocks.delete(caller);
          return #err(#settlementFailed("EVM sender not configured"));
        };
      };

      let execResult = try {
        await sender.executeTransferWithAuthorization(
          chainId, intent.token,
          EvmUtils.hexToBytes(authz.from),
          EvmUtils.hexToBytes(authz.to),
          authz.value, authz.validAfter, authz.validBefore,
          Blob.toArray(authz.nonce),
          authz.v, Blob.toArray(authz.r), Blob.toArray(authz.s),
        );
      } catch (e) {
        sessionOpenLocks.delete(caller);
        return #err(#settlementFailed("EIP-3009 execution failed: " # Error.message(e)));
      };

      let depositTxHash = switch (execResult) {
        case (#ok(hash)) { hash };
        case (#err(msg)) {
          sessionOpenLocks.delete(caller);
          return #err(#settlementFailed("EIP-3009 execution failed: " # msg));
        };
      };

      // Generate session ID once — used for both escrow allocation and session record
      let sessionId = nextSessionId();

      // Allocate in EVM escrow
      switch (evmEscrowManager.allocate(sessionId, chainId, intent.token, deposit)) {
        case (#err(e)) {
          sessionOpenLocks.delete(caller);
          return #err(#settlementFailed(e));
        };
        case (#ok) {};
      };

      // Validate Ed25519 public key
      let sessionPublicKey = switch (sig.publicKey) {
        case (?pk) { pk };
        case (null) {
          sessionOpenLocks.delete(caller);
          return #err(#invalidSignature("Missing publicKey for session voucher signing"));
        };
      };
      if (Blob.toArray(sessionPublicKey).size() != 32) {
        sessionOpenLocks.delete(caller);
        return #err(#invalidSignature("Public key must be 32 bytes (Ed25519)"));
      };

      let now = Time.now();
      let effectivePolicy = policy.getEffectivePolicy(caller);

      let session : Types.InternalSessionState = {
        id = sessionId;
        payer = caller;
        payerPublicKey = sessionPublicKey;
        deposited = deposit;
        var consumed = 0;
        var remaining = deposit;
        var voucherCount = 0;
        var status = #open;
        openedAt = now;
        var lastActivityAt = now;
        var lastSequence = 0;
        var lastCumulativeAmount = 0;
        subaccount = Blob.fromArray([]); // Not used for EVM sessions
        network = intent.network;
        token = intent.token;
        recipient = intent.recipient;
        autoClose = clientConfig.autoClose;
        maxDuration = effectivePolicy.maxSessionDuration;
        idleTimeout = switch (clientConfig.idleTimeout) {
          case (?t) { ?t };
          case (null) { effectivePolicy.sessionIdleTimeout };
        };
        evmDeposit = ?{
          txHash = depositTxHash;
          chainId;
          payerEvmAddress = authz.from;
          tokenAddress = intent.token;
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

      // H-3: Reject vouchers on sessions past their expiry (closes gap between timer runs)
      switch (session.maxDuration) {
        case (?maxDur) {
          if (Time.now() - session.openedAt > maxDur) return #sessionNotOpen;
        };
        case (null) {};
      };
      switch (session.idleTimeout) {
        case (?timeout) {
          if (Time.now() - session.lastActivityAt > timeout) return #sessionNotOpen;
        };
        case (null) {};
      };

      // Check sequence monotonicity
      if (voucher.sequence <= session.lastSequence) return #invalidSequence;

      // M-5: Check cumulative amount is strictly increasing (reject zero-delta vouchers)
      if (voucher.cumulativeAmount <= session.lastCumulativeAmount) return #invalidSequence;

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
      // H-2: Handle Nat64 overflow gracefully instead of trapping
      let payload = switch (encodeVoucherPayload(voucher.sessionId, voucher.cumulativeAmount, voucher.sequence)) {
        case (?p) { p };
        case (null) { return #payloadOverflow };
      };
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

    /// H-1: Close a session with authorization check — only payer can close.
    public func closeSession(caller : Principal, sessionId : Text) : async Types.PaymentResult {
      let session = switch (sessions.get(sessionId)) {
        case (null) { return #settlementFailed("Session not found") };
        case (?s) { s };
      };
      if (not Principal.equal(caller, session.payer)) {
        return #settlementFailed("Not authorized: only session payer can close");
      };
      await closeSessionInternal(sessionId);
    };

    /// Close a session without auth (for timer/admin use).
    /// Dispatches to ICP or EVM close based on the session's network.
    public func closeSessionInternal(sessionId : Text) : async Types.PaymentResult {
      let session = switch (sessions.get(sessionId)) {
        case (null) { return #settlementFailed("Session not found") };
        case (?s) { s };
      };

      if (session.status == #closed or session.status == #closing) {
        return #settlementFailed("Session already closed");
      };

      // Dispatch: EVM sessions use tECDSA-signed ERC-20 transfers
      if (isEvmNetwork(session.network)) {
        return await closeEvmSessionInternal(session);
      };

      let wasExpired = (session.status == #expired);
      // H-4: Setting #closing BEFORE any async operations freezes session.consumed —
      // consumeVoucher rejects vouchers when status != #open, preventing TOCTOU on arithmetic.
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
      var settleBlockIndex : ?Nat = null;
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
          case (#ok(blockIdx)) { settleBlockIndex := ?blockIdx };
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
      var refundBlockIndex : ?Nat = null;
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
          case (#ok(blockIdx)) { refundBlockIndex := ?blockIdx };
        };
      };

      session.status := if (wasExpired) { #expired } else { #closed };

      // Build txHash from ICRC-1 block indices
      let closeTxHash : ?Text = switch (settleBlockIndex, refundBlockIndex) {
        case (?s, ?r) { ?("settle:" # Nat.toText(s) # "|refund:" # Nat.toText(r)) };
        case (?s, null) { ?("settle:" # Nat.toText(s)) };
        case (null, ?r) { ?("refund:" # Nat.toText(r)) };
        case (null, null) { null };
      };

      #ok({
        id = "rcpt-close"; // Overwritten by Gateway.closeSession() / forceCloseSession()
        amount = session.consumed;
        token = session.token;
        sender = Principal.toText(session.payer);
        recipient = session.recipient;
        network = session.network;
        timestamp = Time.now();
        txHash = closeTxHash;
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

      let resultBuf = Array.init<Types.PaymentResult>(buf.size(), #expired("Session expired"));
      var i = 0;
      for ((sessionId, session) in buf.vals()) {
        session.status := #expired;
        let result = await closeSessionInternal(sessionId);
        resultBuf[i] := result;
        i += 1;
      };
      Array.freeze(resultBuf);
    };

    /// H-1: Remove closed/expired sessions older than the retention period from memory.
    /// Called after closeExpiredSessions to prevent unbounded HashMap growth.
    public func gcClosedSessions() {
      let retentionNanos = 24 * 60 * 60 * 1_000_000_000; // 24 hours
      let now = Time.now();
      let toRemove = Iter.toArray(
        Iter.filter<(Text, Types.InternalSessionState)>(
          sessions.entries(),
          func((_, s)) {
            (s.status == #closed or s.status == #expired) and (now - s.lastActivityAt > retentionNanos);
          },
        )
      );
      for ((id, _) in toRemove.vals()) {
        sessions.delete(id);
      };
    };

    // ── EVM session close ──

    /// Close an EVM session: settle consumed to recipient, refund remainder to payer.
    /// Both operations use tECDSA-signed ERC-20 transfer transactions.
    func closeEvmSessionInternal(session : Types.InternalSessionState) : async Types.PaymentResult {
      let wasExpired = (session.status == #expired);
      session.status := #closing;

      let deposit = switch (session.evmDeposit) {
        case (?d) { d };
        case (null) {
          session.status := if (wasExpired) { #expired } else { #closed };
          return #settlementFailed("Session has no EVM deposit data");
        };
      };

      let sender = switch (evmSender) {
        case (?s) { s };
        case (null) {
          session.status := #open;
          return #settlementFailed("EVM sender not configured (ecdsaKeyName missing)");
        };
      };

      // Settle consumed amount to recipient
      var settleTxHash : ?Text = null;
      if (session.consumed > 0) {
        let settleResult = await sender.sendErc20Transfer(
          deposit.chainId, deposit.tokenAddress, session.recipient, session.consumed,
        );
        switch (settleResult) {
          case (#err(msg)) {
            session.status := #open;
            return #settlementFailed("EVM settle: " # msg);
          };
          case (#ok(hash)) { settleTxHash := ?hash };
        };
      };

      // Refund remainder to payer (no ledger fees to subtract for EVM — gas is in ETH)
      var refundTxHash : ?Text = null;
      let refunded = if (session.deposited > session.consumed) {
        session.deposited - session.consumed;
      } else { 0 };

      if (refunded > 0) {
        let refundResult = await sender.sendErc20Transfer(
          deposit.chainId, deposit.tokenAddress, deposit.payerEvmAddress, refunded,
        );
        switch (refundResult) {
          case (#err(msg)) {
            // C-1: Settlement succeeded but refund failed — leave session in #closing
            // so the unconsumed funds are not lost. The payer (or admin) can call
            // recoverEscrow() to retrieve the stuck refund amount.
            // DO NOT mark as #closed — that would silently discard the refund.
            return #settlementFailed("EVM refund failed (settle succeeded, session left in #closing): " # msg);
          };
          case (#ok(hash)) { refundTxHash := ?hash };
        };
      };

      // Deallocate from EVM escrow
      ignore evmEscrowManager.deallocate(session.id);

      session.status := if (wasExpired) { #expired } else { #closed };

      // Include both tx hashes in the receipt (settle|refund)
      let combinedTxHash = switch (settleTxHash, refundTxHash) {
        case (?s, ?r) { ?(s # "|" # r) };
        case (?s, null) { ?s };
        case (null, ?r) { ?r };
        case (null, null) { null };
      };

      #ok({
        id = "rcpt-close";
        amount = session.consumed;
        token = session.token;
        sender = Principal.toText(session.payer);
        recipient = session.recipient;
        network = session.network;
        timestamp = Time.now();
        txHash = combinedTxHash;
        sessionId = ?session.id;
        refunded = ?refunded;
      });
    };

    /// M-8: Recover funds from an escrow subaccount.
    /// H-5: Hardened — always refunds to payer, caps at unconsumed amount,
    /// and only allows recovery for sessions in #closed, #expired, or #closing status.
    public func recoverEscrow(
      caller : Principal,
      ledger : Types.LedgerActor,
      sessionId : Text,
      amount : Nat,
    ) : async { #ok : Nat; #err : Text } {
      // Check authorization — only session payer can recover
      switch (sessions.get(sessionId)) {
        case (?session) {
          if (not Principal.equal(caller, session.payer)) {
            return #err("Not authorized: only session payer can recover escrow");
          };
          // H-5: Only allow recovery for terminal or stuck sessions
          switch (session.status) {
            case (#closed or #expired or #closing) {};
            case (#open) {
              return #err("Cannot recover escrow from an open session — close it first");
            };
          };
          // H-5: Cap recovery amount to unconsumed portion
          let maxRecoverable = if (session.deposited > session.consumed) {
            session.deposited - session.consumed;
          } else { 0 };
          let cappedAmount = if (amount > maxRecoverable) { maxRecoverable } else { amount };
          if (cappedAmount == 0) {
            return #err("No recoverable funds: deposit fully consumed");
          };
          // H-5: Always refund to the payer's own account (no arbitrary recipient)
          let payerAccount : Types.Account = { owner = session.payer; subaccount = null };
          let subaccount = escrowManager.deriveSubaccount(sessionId);
          await escrowManager.refund(ledger, subaccount, payerAccount, cappedAmount);
        };
        case (null) {
          return #err("Session not found: cannot authorize escrow recovery without session record");
        };
      };
    };

    // ── Stable state ──

    /// Serialize all active sessions for stable storage.
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
              evmDeposit = s.evmDeposit;
            };
          },
        )
      );
    };

    /// Restore sessions from stable storage.
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
          evmDeposit = ss.evmDeposit;
        };
        sessions.put(ss.id, session);
      };
    };
  };
};
