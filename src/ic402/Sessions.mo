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
  /// CBOR array(4): [text(canisterId), text(sessionId), uint(cumulativeAmount), uint(sequence)]
  /// M-7 (v2): `canisterId` (the verifying canister's principal text) is now bound
  /// into the signed payload so a voucher signed for canister A cannot be replayed
  /// against canister B when the payer reuses the same Ed25519 key across canisters.
  /// H-2: Returns null if cumulativeAmount or sequence exceeds Nat64 range.
  public func encodeVoucherPayload(canisterId : Text, sessionId : Text, cumulativeAmount : Nat, sequence : Nat) : ?[Nat8] {
    // H-2: Bounds check before Nat64 conversion to prevent trap
    let maxNat64 : Nat = 18_446_744_073_709_551_615;
    if (cumulativeAmount > maxNat64 or sequence > maxNat64) { return null };

    let value : CBOR.Value = #majorType4([
      #majorType3(canisterId),
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

  /// Pure decision for reconcileSession (module-level → unit-testable without a Sessions instance).
  /// An EVM session close is TWO-PHASE: settle consumed → operator, THEN refund remainder → payer.
  /// Rules (golden): finalize ONLY on #confirmed; never on #pending/#reverted/#err. A confirmed
  /// REFUND completes the close (settle already confirmed before the refund leg ran). A confirmed
  /// SETTLE completes only if no remainder is owed; otherwise the refund is still UNSENT and can't
  /// be auto-broadcast confirm-only → defer to the manual hatch (forceResolveSession + sweepEvm).
  public type SessionReconcileResult = {
    #finalizeClose : Text; // settle+refund resolved → #closed (dealloc + daily credit-back)
    #settleDoneRefundOwed : Text; // settle confirmed but remainder unsent → manual
    #stay : Text; // no change; surface the reason
  };
  /// Pure decision for reconciling a parked EVM session-close leg: finalize only on a #confirmed
  /// leg (see the golden rules above), otherwise stay parked.
  public func sessionReconcileDecision(
    outcome : { #confirmed; #reverted; #pending; #err : Text },
    leg : { #Settle; #Refund },
    refundOwed : Nat,
  ) : SessionReconcileResult {
    switch (outcome) {
      case (#pending) { #stay("Parked close tx still pending — stay parked") };
      case (#reverted) { #stay("Parked close tx reverted on-chain; no funds moved — use forceResolveSession") };
      case (#err(e)) { #stay("Confirm RPC failed — stay parked: " # e) };
      case (#confirmed) {
        switch (leg) {
          case (#Refund) { #finalizeClose("Refund confirmed on-chain; session #closed") };
          case (#Settle) {
            if (refundOwed == 0) { #finalizeClose("Settle confirmed on-chain (no remainder); session #closed") } else {
              #settleDoneRefundOwed("Settle confirmed on-chain but the remainder refund is unsent — forceResolveSession + sweepEvm to return it");
            };
          };
        };
      };
    };
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
    // Recovery: a session whose EVM close settle/refund parked (#pending) records the parked leg
    // + tx hash here so reconcileSession can re-poll it confirm-only. Transient (not in
    // StableSession; a parked session mid-upgrade falls under the B1 fresh-deploy waiver).
    let closeParkedTxs = HashMap.HashMap<Text, { leg : { #Settle; #Refund }; txHash : Text }>(8, Text.equal, Text.hash);
    // Per-caller lock to prevent concurrent openSession TOCTOU.
    // Stores timestamp so stale locks (from failed async calls) auto-expire after 5 minutes.
    let sessionOpenLocks = HashMap.HashMap<Principal, Int>(8, Principal.equal, Principal.hash);

    // M8: transient tracker of INBOUND EVM deposits that were BROADCAST but not confirmed within
    // openEvmSession's poll budget — they MAY still mine into the shared pool. Keyed by tx hash.
    // Transient like closeParkedTxs (NOT in StableSession): pending deposits are short-lived, so an
    // operator DRAINS before upgrading — setDrainMode(true) rejects new opens, wait for
    // pendingEvmDepositCount() == 0, then upgrade — rather than persisting them across upgrades.
    // Recovered via reconcileEvmDeposit (refund-on-confirm). A deposit still pending across an
    // upgrade is dropped from the tracker, but its tx hash is in the #settlementPending error for a
    // manual sweepEvm.
    type PendingEvmDeposit = { payer : Principal; payerEvmAddress : Text; chainId : Nat; token : Text; amount : Nat; createdAt : Int };
    let pendingEvmDeposits = HashMap.HashMap<Text, PendingEvmDeposit>(8, Text.equal, Text.hash);
    // M8: when true, openEvmSession rejects new inbound deposits so the tracker can drain to 0
    // before an upgrade. Transient — resets to false after upgrade (nothing is pending post-upgrade).
    var drainMode : Bool = false;

    // SEC-0 (round 2): GLOBAL rate-limit hook for the expensive ecRecover in openEvmSession. The
    // Gateway injects its own admitRate (the caller-agnostic token bucket shared with settle/
    // verifyPayment); defaults to a no-op so unit tests constructing Sessions directly are unaffected.
    var admitRateFn : () -> { #ok; #throttled } = func() : { #ok; #throttled } { #ok };
    /// Wire the global rate-limit gate for openEvmSession's ecRecover (injected by the Gateway).
    public func setAdmitRate(f : () -> { #ok; #throttled }) { admitRateFn := f };

    func findLedger(identifier : Text) : ?Types.TokenConfig {
      Utils.findLedger(config.tokens, identifier);
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

    /// Generate a session offer for a 402 response.
    /// TRAPS if intent.suggestedDeposit == 0 or intent.expiry <= Time.now() (expiry is in
    /// NANOSECONDS since epoch, like Time.now()) — validate client-influenced input first.
    public func offerSession(intent : Types.SessionIntent) : Types.SessionIntent {
      if (intent.suggestedDeposit == 0) { Debug.trap("ic402: offerSession() called with suggestedDeposit = 0") };
      if (intent.expiry <= Time.now()) { Debug.trap("ic402: offerSession() called with expired intent") };
      intent;
    };

    /// Open a streaming session. Dispatches on `intent.network`: ICP (`icp:1`) pulls an ICRC-2
    /// deposit into a per-session escrow subaccount; EVM (`eip155:*`) executes an EIP-3009
    /// deposit to the canister's derived EVM address (authorization.value must EQUAL the
    /// deposit; overpayment is rejected as non-creditable).
    ///
    /// The credited deposit is min(intent.suggestedDeposit, clientConfig.maxDeposit), and must
    /// meet intent.minDeposit. `sig.publicKey` MUST be the payer's 32-byte Ed25519 key (used to
    /// verify vouchers); `sig.signature` is unused for sessions. `caller` MUST be the
    /// authenticated msg.caller — it becomes the session payer with close/refund rights.
    ///
    /// EVM: may return #err(#settlementPending(...)): the deposit tx was broadcast but not
    /// confirmed — NO session exists; the deposit is tracked for reconcileEvmDeposit(txHash).
    /// A per-caller open lock (auto-expiring after 5 min) rejects concurrent opens with
    /// #policyDenied.
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
        return #err(#expired("Session intent expired — intents carry a nanosecond expiry set by the server. Request a fresh intent (requestSession/offerSession) and open the session before it lapses."));
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
            return #err(#policyDenied("Session open already in progress for this caller — concurrent opens are serialized. Wait for the in-flight open to finish and retry; a lock stranded by a failed call auto-expires after 5 minutes."));
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

      // M7/SEC-0: validate the Ed25519 session public key BEFORE pulling the deposit on-chain,
      // so a missing/malformed key fails cheaply without moving funds. The old placement
      // validated AFTER the deposit and then refunded the FULL `deposit` — which ALWAYS failed:
      // the escrow subaccount holds exactly `deposit`, and icrc1_transfer deducts the fee ON TOP,
      // so it needs deposit+fee. Worse, those paths return before `sessions.put`, so no session
      // record exists and recoverEscrow can't find it — the deposit was unrecoverable in-band.
      let sessionPublicKey = switch (sig.publicKey) {
        case (?pk) { pk };
        case (null) {
          sessionOpenLocks.delete(caller);
          return #err(#invalidSignature("Missing publicKey in PaymentSignature (required for sessions)"));
        };
      };
      if (Blob.toArray(sessionPublicKey).size() != 32) {
        sessionOpenLocks.delete(caller);
        return #err(#invalidSignature("Public key must be 32 bytes (Ed25519)"));
      };

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
            // Refund the deposit. M7: the escrow subaccount holds exactly `deposit`, and
            // icrc1_transfer deducts the ledger fee ON TOP of the amount — so refund deposit−fee,
            // not the full `deposit` (which fails InsufficientFunds and strands the funds).
            // Best-effort: if this transfer itself fails (transient ledger error) the funds need
            // manual controller recovery, since no session record exists yet.
            let fee : Nat = try { await ledger.icrc1_fee() } catch (_) { 10_000 };
            let _refundResult = await escrowManager.refund(
              ledger, subaccount,
              { owner = caller; subaccount = null },
              Utils.satSub(deposit, fee),
            );
            sessionOpenLocks.delete(caller);
            return #err(#policyDenied("Concurrent session limit reached while the deposit was in flight — no session was opened; the deposit was refunded minus the ledger fee. Close an existing session (or raise maxConcurrentSessions) and retry."));
          };
        };
        case (null) {};
      };

      // (Ed25519 public key was validated above, before the on-chain deposit.)
      let now = Time.now();
      let session : Types.InternalSessionState = {
        id = sessionId;
        payer = caller;
        payerPublicKey = sessionPublicKey;
        deposited = deposit;
        spendDay = policy.currentDay();
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

      // M8: reject new inbound EVM deposits while draining for an upgrade — BEFORE any funds move
      // or the lock is taken. The operator sets drain mode, waits for pendingEvmDepositCount() to
      // reach 0, then upgrades, so no in-flight deposit is lost across the (transient) tracker.
      if (drainMode) {
        return #err(#settlementFailed("Canister is draining for a pending upgrade — new EVM sessions are temporarily unavailable, retry shortly"));
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
            return #err(#policyDenied("Session open already in progress for this caller — concurrent opens are serialized. Wait for the in-flight open to finish and retry; a lock stranded by a failed call auto-expires after 5 minutes."));
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

      // C-1 (v2): The EIP-3009 deposit recipient MUST be the canister's own EVM
      // address. Without this, an attacker signs a self-transfer (to = an address
      // they control), the canister credits them an escrow `deposit` they never
      // actually paid in, and on close the refund is drawn from the canister's own
      // pooled balance — draining everyone else's deposits. The constructor is
      // passed evmRecipientAddress precisely for this check.
      let canisterEvmAddr = switch (evmRecipientAddress.get()) {
        case (?addr) { addr };
        case (null) { sessionOpenLocks.delete(caller); return #err(#settlementFailed("Canister EVM address not derived yet — tECDSA derivation is async. Ensure startTimers() was called (or call deriveEvmRecipient), poll isEvmReady() until true, and check logs for 'EVM address derivation failed'. Transient at startup; retry after derivation.")) };
      };
      if (not EvmUtils.addressesEqual(authz.to, canisterEvmAddr)) {
        sessionOpenLocks.delete(caller);
        return #err(#invalidSignature("EIP-3009 deposit recipient (to) must be the canister's EVM address (" # canisterEvmAddr # ")"));
      };

      // Validate authorization amount. SEC-0: the signed value must EQUAL the credited deposit.
      // executeTransferWithAuthorization below pulls the FULL authz.value on-chain, but the
      // session only credits/allocates `deposit` — so accepting authz.value > deposit pulls USDC
      // that is never credited and can never be refunded (close caps the refund at deposited −
      // consumed). The excess strands in the shared EVM pool. Mirror the charge path's
      // value == amount (Gateway.settle).
      if (authz.value < deposit) {
        sessionOpenLocks.delete(caller);
        return #err(#depositBelowMinimum(deposit));
      };
      if (authz.value > deposit) {
        sessionOpenLocks.delete(caller);
        return #err(#invalidSignature("EIP-3009 deposit value (" # Nat.toText(authz.value) # ") must equal the session deposit (" # Nat.toText(deposit) # "); overpayment is not creditable"));
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
      // Multi-token: key the EIP-712 domain off the SESSION's token (tokenAddr = intent.token), not
      // tokens[0], so a deposit in a non-first configured token verifies against its OWN domain.
      for (tok in evmChain.tokens.vals()) {
        if (EvmUtils.addressesEqual(tok.address, tokenAddr)) {
          tokenName := tok.name;
          tokenVersion := tok.version;
        };
      };

      // SEC-0 (round 2): rate-limit the expensive ecRecover in verifyAuthorization below behind the
      // GLOBAL token bucket. openEvmSession is a public, unauthenticated entry callable with a forged
      // EIP-3009; its per-caller policy limit is mintable (fresh principals), so without this the
      // unmetered-ecRecover cycle-DoS is reachable on the session rail (the settle/verifyPayment gate
      // alone did not cover it). admitRateFn is injected by the Gateway (no-op default for unit tests).
      switch (admitRateFn()) {
        case (#ok) {};
        case (#throttled) {
          sessionOpenLocks.delete(caller);
          return #err(#policyDenied("Rate limited: global facilitator admission bucket exhausted (shared across settle/verify/session-open). Transient — retry with backoff; heavy /verify traffic can starve settlement."));
        };
      };

      // SEC-0 (round 2): validate the Ed25519 session public key HERE — before the on-chain deposit
      // and the escrow allocation below — so an invalid key fails cheaply WITHOUT pulling funds or
      // leaking an escrow allocation. The old placement validated AFTER allocate(), which (under a
      // live poolCap) permanently burned pool headroom and stranded an already-pulled deposit.
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
        return #err(#invalidSignature("EIP-3009 authorization signature verification failed — the recovered signer does not match authorization.from. Check the EIP-712 domain matches this canister's config (token name/version, chainId, verifyingContract = the paid asset) and that the signer key controls the from address. Not retryable without re-signing."));
      };

      // Execute transferWithAuthorization via tECDSA (canister acts as facilitator)
      let sender = switch (evmSender) {
        case (?s) { s };
        case (null) {
          sessionOpenLocks.delete(caller);
          return #err(#settlementFailed("EVM sender not configured"));
        };
      };

      // Generate the session ID once — used for both the escrow reservation and the session record.
      let sessionId = nextSessionId();

      // H3/SEC-0: RESERVE the pool allocation BEFORE pulling the deposit on-chain. Running the
      // poolCap check AFTER the transfer (the old placement) meant an honest open that exceeded
      // remaining headroom pulled the payer's USDC into the shared pool and THEN failed with no
      // session and no refund — funds stranded pending a manual sweepEvm. allocate() is
      // synchronous (no await), so concurrent opens serialize on the cap here and the check can
      // never be raced across the multi-await deposit confirm. EVERY failure after this point
      // must deallocate() so the reservation does not leak pool headroom.
      switch (evmEscrowManager.allocate(sessionId, chainId, intent.token, deposit)) {
        case (#err(e)) {
          sessionOpenLocks.delete(caller);
          return #err(#settlementFailed(e));
        };
        case (#ok) {};
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
        ignore evmEscrowManager.deallocate(sessionId); // H3: release the reservation — no funds moved.
        sessionOpenLocks.delete(caller);
        return #err(#settlementFailed("EIP-3009 execution failed: " # Error.message(e)));
      };

      let depositTxHash = switch (execResult) {
        case (#ok(hash)) { hash };
        case (#err(msg)) {
          ignore evmEscrowManager.deallocate(sessionId); // H3: pre-broadcast failure — release reservation.
          sessionOpenLocks.delete(caller);
          return #err(#settlementFailed("EIP-3009 execution failed: " # msg));
        };
        // G5/G6: ambiguous broadcast (may still mine) — keep its hash and route it into the confirm
        // poll below, so if it mines the session opens, and if it stays pending it is tracked in
        // pendingEvmDeposits + surfaced as #settlementPending (recoverable via reconcileEvmDeposit),
        // rather than stranded as a hash-less #settlementFailed. Single-use EIP-3009 nonce → no double-pay.
        case (#maybeSent(m)) { m.txHash };
      };

      // H-1 (v2): Confirm the deposit transfer actually mined before crediting an
      // escrow allocation. Otherwise a reverted/never-mined deposit would still
      // open a funded session whose refund is drawn from the canister's balance.
      switch (await sender.confirmTransaction(chainId, depositTxHash, 4)) {
        case (#confirmed) {};
        case (#reverted) {
          ignore evmEscrowManager.deallocate(sessionId); // H3: reverted → no funds moved, release reservation.
          sessionOpenLocks.delete(caller);
          return #err(#settlementFailed("EVM deposit reverted on-chain (tx " # depositTxHash # ")"));
        };
        case (#pending) {
          // H3: release the pool reservation so it does not leak headroom. M8: track the
          // broadcast-but-unconfirmed deposit so it can be reconciled (refunded) if it later mines,
          // instead of stranding unattributed in the shared pool.
          ignore evmEscrowManager.deallocate(sessionId);
          pendingEvmDeposits.put(depositTxHash, { payer = caller; payerEvmAddress = authz.from; chainId; token = intent.token; amount = deposit; createdAt = Time.now() });
          sessionOpenLocks.delete(caller);
          return #err(#settlementPending("EVM deposit broadcast but not yet confirmed (tx " # depositTxHash # ") — no session was created. If the tx mines, the deposit lands in the shared pool: call reconcileEvmDeposit with this tx hash to refund it, then open a new session. Do not re-sign the same authorization."));
        };
        case (#err(e)) {
          // H3: release reservation. M8: track for reconcile (see #pending).
          ignore evmEscrowManager.deallocate(sessionId);
          pendingEvmDeposits.put(depositTxHash, { payer = caller; payerEvmAddress = authz.from; chainId; token = intent.token; amount = deposit; createdAt = Time.now() });
          sessionOpenLocks.delete(caller);
          return #err(#settlementPending("EVM deposit broadcast; confirmation unavailable: " # e # " (tx " # depositTxHash # ") — no session was created; the deposit is tracked. Retry reconcileEvmDeposit with this tx hash once the RPC recovers (refund-on-confirm)."));
        };
      };

      // (Session ID + escrow reservation were established above, BEFORE the on-chain deposit.)
      let now = Time.now();
      let effectivePolicy = policy.getEffectivePolicy(caller);

      let session : Types.InternalSessionState = {
        id = sessionId;
        payer = caller;
        payerPublicKey = sessionPublicKey;
        deposited = deposit;
        spendDay = policy.currentDay();
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

    /// Verify a cumulative voucher and return the incremental delta (#ok(cumulative − last)).
    /// Synchronous — no awaits. Acceptance requires: session #open and within
    /// maxDuration/idleTimeout (otherwise #sessionNotOpen, even before the expiry timer runs);
    /// sequence STRICTLY increasing; cumulativeAmount STRICTLY increasing (zero-delta →
    /// #invalidSequence) and ≤ deposited; both values ≤ Nat64 max (#payloadOverflow);
    /// a 64-byte Ed25519 signature by the session's payerPublicKey over the CBOR payload
    /// [canisterId, sessionId, cumulativeAmount, sequence] (see encodeVoucherPayload — the
    /// canister principal is bound in, so vouchers are not replayable across canisters).
    /// Deltas are NOT counted against the daily limit (the full deposit was counted at open).
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
      // M-7: Bind the verifying canister's principal into the signed payload.
      let payload = switch (encodeVoucherPayload(Principal.toText(canisterPrincipal), voucher.sessionId, voucher.cumulativeAmount, voucher.sequence)) {
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

      // M-9 (v2): Do NOT record per-voucher deltas against the daily limit. The
      // full deposit is recorded once at openSession; the unused remainder is
      // credited back on close (releaseDaily). Recording deltas here as well
      // double-counted spend (deposit + every delta) and was never refunded.

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

    /// Close a session (no auth — timer/admin use; payer-authenticated callers use closeSession).
    /// Two-leg fund movement: settle `consumed` → recipient, then refund the remainder → payer.
    /// Rejects sessions already #closed or #closing (recovery goes through reconcileSession /
    /// forceResolveSession, never a re-close).
    ///
    /// ICP: ledger fees come out of the refund (refunded = deposited − consumed − fees). If the
    /// settle leg succeeds but the refund leg fails, the session is still marked #closed and
    /// #settlementFailed("Refund: …") is returned — the remainder stays in the escrow
    /// subaccount and is recoverable via recoverEscrow.
    ///
    /// EVM: finalizes ONLY on confirmed transfers. #settlementPending → the session is PARKED
    /// in #closing with the tx hash recorded; recover with reconcileSession (confirm-only —
    /// re-broadcasting risks double-pay). A pre-broadcast #err on a client-initiated close may
    /// REOPEN the session to #open (safe to retry); after a confirmed settle, failures leave
    /// #closing for manual recovery. On full success the receipt's txHash is "settle|refund".
    public func closeSessionInternal(sessionId : Text) : async Types.PaymentResult {
      let session = switch (sessions.get(sessionId)) {
        case (null) { return #settlementFailed("Session not found") };
        case (?s) { s };
      };

      if (session.status == #closed or session.status == #closing) {
        return #settlementFailed("Session already closed or a close is in progress (#closing) — do not re-close. If it is stuck in #closing (parked EVM close), recover with reconcileSession (confirm-only) or forceResolveSession + manual sweep.");
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
      let escrowBalance = Utils.satSub(session.deposited, session.consumed + settleFees);
      var refundBlockIndex : ?Nat = null;
      let refunded = Utils.satSub(escrowBalance, fee);
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
            return #settlementFailed("Refund leg failed (settle succeeded; session marked #closed): " # msg # " — the remainder stays in the session's escrow subaccount and is recoverable by the payer via recoverEscrow(sessionId).");
          };
          case (#ok(blockIdx)) { refundBlockIndex := ?blockIdx };
        };
      };

      session.status := if (wasExpired) { #expired } else { #closed };

      // M-9 (v2): Credit the unused deposit back against the daily limit (the full
      // deposit was reserved at open; only `consumed` should count as spend).
      if (session.deposited > session.consumed) {
        policy.releaseDaily(session.payer, session.spendDay, session.deposited - session.consumed);
      };

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
      for ((sessionId, _) in buf.vals()) {
        // H1/S-3: `buf` is a pre-await snapshot. During an earlier iteration's multi-await
        // EVM settle, a session later in `buf` may have been concurrently finalized to
        // #closed (by the payer's own closeSession, or an overlapping expiry-timer run).
        // Re-fetch the CURRENT state and only expire sessions still #open — blindly
        // re-stamping #expired would flip a terminal #closed back into a status the re-close
        // guard (closeSessionInternal rejects only #closed/#closing) does NOT reject, letting
        // closeEvmSessionInternal broadcast a SECOND settle+refund from the shared EVM pool
        // and drain other payers' deposits (the exact double-settle S-3 ends closes in
        // #closed to prevent).
        switch (sessions.get(sessionId)) {
          case (?session) {
            if (session.status == #open) {
              session.status := #expired;
              resultBuf[i] := await closeSessionInternal(sessionId);
            } else {
              resultBuf[i] := #settlementFailed("Session no longer open — skipped by expiry sweep (concurrently closed)");
            };
          };
          case (null) {
            resultBuf[i] := #settlementFailed("Session vanished before expiry sweep");
          };
        };
        i += 1;
      };
      Array.freeze(resultBuf);
    };

    /// H-1: Remove closed/expired sessions older than the retention period from memory.
    /// Observability (NEW-4): counts of sessions by status. `closing` is the parked count —
    /// an EVM session close that broadcast a settle/refund but hasn't confirmed; a non-zero,
    /// non-decreasing `closing` means a client deposit is parked mid-close and needs attention.
    public func sessionCounts() : {
      total : Nat; open : Nat; closing : Nat; closed : Nat; expired : Nat;
    } {
      var total = 0; var nOpen = 0; var nClosing = 0; var nClosed = 0; var nExpired = 0;
      for ((_, s) in sessions.entries()) {
        total += 1;
        switch (s.status) {
          case (#open) { nOpen += 1 };
          case (#closing) { nClosing += 1 };
          case (#closed) { nClosed += 1 };
          case (#expired) { nExpired += 1 };
        };
      };
      { total; open = nOpen; closing = nClosing; closed = nClosed; expired = nExpired };
    };

    /// Finalize a #closing session to terminal #closed, releasing BOTH canister-side reservations
    /// it still holds — the EVM escrow POOL ALLOCATION (deallocate) and the unconsumed DAILY-SPEND
    /// reservation (releaseDaily) — and clearing any parked close tx. Shared by every #closing→#closed
    /// transition (reconcileSession's confirmed close and the forceResolveSession operator hatch) so
    /// they cannot drift: dropping deallocate here previously leaked the pool allocation PERMANENTLY
    /// on the force path (gcClosedSessions only deletes the record, it never deallocates), monotonically
    /// shrinking the funded pool's headroom until allocate() refuses new sessions. The reservations are
    /// pure accounting (no funds move); the operator reconciles the on-chain funds out-of-band.
    private func finalizeClosedSession(s : Types.InternalSessionState) {
      ignore evmEscrowManager.deallocate(s.id);
      s.status := #closed;
      closeParkedTxs.delete(s.id);
      if (s.deposited > s.consumed) { policy.releaseDaily(s.payer, s.spendDay, s.deposited - s.consumed) };
    };

    /// Operator escape hatch for a session STUCK in #closing (an EVM close whose settle/refund
    /// broadcast but never confirmed). Moves NO funds; the operator reconciles the on-chain EVM
    /// pool out-of-band. Releases the session's canister-side reservations and forces it to #closed
    /// so GC can reclaim it. The consumer MUST gate this on Principal.isController.
    public func forceResolveSession(sessionId : Text) : { #ok; #err : Text } {
      switch (sessions.get(sessionId)) {
        case (null) { #err("Session not found") };
        case (?s) {
          if (s.status != #closing) {
            return #err("Session is not stuck in #closing (status: " # debug_show (s.status) # ")");
          };
          finalizeClosedSession(s);
          #ok;
        };
      };
    };

    /// v2.1.1 recovery (controller-only via the consumer): CONFIRM-ONLY finalize an EVM session
    /// parked in #closing. Re-polls the stored parked close tx and applies sessionReconcileDecision
    /// — NEVER broadcasts. A confirmed refund (or a confirmed settle with no remainder) → #closed;
    /// a confirmed settle WITH a remainder still owed can't be auto-completed confirm-only (the
    /// refund is unsent) → forceResolveSession + sweepEvm. #pending/#reverted/#err → stay parked.
    public func reconcileSession(sessionId : Text) : async { #ok : Text; #err : Text } {
      let session = switch (sessions.get(sessionId)) { case (null) { return #err("Session not found") }; case (?s) { s } };
      if (session.status != #closing) return #err("Session is not parked in #closing (status: " # debug_show (session.status) # ")");
      let parked = switch (closeParkedTxs.get(sessionId)) { case (null) { return #err("Session is #closing but has no parked tx — use forceResolveSession") }; case (?p) { p } };
      let deposit = switch (session.evmDeposit) { case (null) { return #err("Session has no EVM deposit data") }; case (?d) { d } };
      let sender = switch (evmSender) { case (null) { return #err("EVM sender not configured") }; case (?s) { s } };
      let outcome = await sender.confirmTransaction(deposit.chainId, parked.txHash, 1);
      // Re-fetch after the await: a concurrent transition may have moved the session.
      let s2 = switch (sessions.get(sessionId)) { case (null) { return #err("Session vanished during reconcile") }; case (?s) { s } };
      if (s2.status != #closing) return #err("Session no longer #closing (status: " # debug_show (s2.status) # ")");
      let refundOwed = Utils.satSub(s2.deposited, s2.consumed);
      switch (sessionReconcileDecision(outcome, parked.leg, refundOwed)) {
        case (#finalizeClose(msg)) {
          finalizeClosedSession(s2); // deallocate + #closed + clear park + releaseDaily (shared with forceResolveSession)
          #ok(msg # " (tx " # parked.txHash # ")");
        };
        case (#settleDoneRefundOwed(msg)) {
          // Settle confirmed; clear the (now-resolved) settle park so a re-reconcile doesn't loop.
          // The remainder refund is unsent — operator forceResolveSession + sweepEvm to return it.
          closeParkedTxs.delete(sessionId);
          #err(msg # " (tx " # parked.txHash # ")");
        };
        case (#stay(err)) { #err(err # " (tx " # parked.txHash # ")") };
      };
    };

    // ── M8: inbound EVM deposit drain + reconcile ──

    /// M8: number of inbound EVM deposits that were broadcast but not yet confirmed/reconciled.
    /// Operators poll this after setDrainMode(true) and upgrade only once it reaches 0, so no
    /// pending deposit is lost across the transient tracker.
    public func pendingEvmDepositCount() : Nat { pendingEvmDeposits.size() };

    /// M8: list the tracked pending inbound EVM deposits (observability / manual recovery).
    public func listPendingEvmDeposits() : [{ txHash : Text; payer : Principal; payerEvmAddress : Text; chainId : Nat; token : Text; amount : Nat; createdAt : Int }] {
      Iter.toArray(
        Iter.map<(Text, PendingEvmDeposit), { txHash : Text; payer : Principal; payerEvmAddress : Text; chainId : Nat; token : Text; amount : Nat; createdAt : Int }>(
          pendingEvmDeposits.entries(),
          func((h, d)) { { txHash = h; payer = d.payer; payerEvmAddress = d.payerEvmAddress; chainId = d.chainId; token = d.token; amount = d.amount; createdAt = d.createdAt } },
        )
      );
    };

    /// M8: get/set drain mode. When true, openEvmSession rejects new inbound deposits so the
    /// tracker can drain to 0 before an upgrade. Controller-gated by the consumer canister.
    public func setDrainMode(on : Bool) { drainMode := on };
    public func getDrainMode() : Bool { drainMode };

    /// M8: reconcile a tracked pending inbound deposit. Polls the deposit tx receipt; on a mined
    /// status==1 (the deposit landed in the shared pool) it REFUNDS the amount to the payer's EVM
    /// address; on a mined revert it drops the entry (nothing landed); otherwise leaves it for a
    /// later retry. The entry is claimed synchronously before the first await so two concurrent
    /// reconciles of the same tx can't double-refund. Controller-gated by the consumer.
    public func reconcileEvmDeposit(txHash : Text) : async { #refunded : Text; #reverted; #stillPending; #notFound; #err : Text } {
      let dep = switch (pendingEvmDeposits.get(txHash)) { case (?d) { d }; case (null) { return #notFound } };
      let sender = switch (evmSender) { case (?s) { s }; case (null) { return #err("EVM sender not configured") } };
      // Claim synchronously (no await between get and delete) so a concurrent reconcile of the same
      // tx sees #notFound and cannot double-refund. Restore on any non-terminal outcome.
      pendingEvmDeposits.delete(txHash);
      switch (await sender.confirmTransaction(dep.chainId, txHash, 4)) {
        case (#confirmed) {
          // Deposit mined into the shared pool — refund it to the payer's EVM address.
          switch (await sender.sendErc20TransferConfirmed(dep.chainId, dep.token, dep.payerEvmAddress, dep.amount, 4)) {
            case (#confirmed(h)) { #refunded(h) }; // stays deleted — done
            case (#reverted(h)) { pendingEvmDeposits.put(txHash, dep); #err("refund reverted on-chain (tx " # h # ") — retry reconcile") };
            // Refund broadcast but unconfirmed — do NOT restore (it may land; restoring risks a
            // double refund on retry). Operator verifies the tx before any manual re-refund.
            case (#pending(h)) { #err("refund broadcast but not confirmed (tx " # h # ") — verify on-chain before retrying to avoid double refund") };
            case (#err(e)) { pendingEvmDeposits.put(txHash, dep); #err("refund failed (nothing broadcast): " # e) };
          };
        };
        case (#reverted) { #reverted }; // deposit never landed — nothing to refund; stays dropped
        case (#pending) { pendingEvmDeposits.put(txHash, dep); #stillPending };
        case (#err(e)) { pendingEvmDeposits.put(txHash, dep); #err("receipt poll failed: " # e) };
      };
    };

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
          // S16/C1: leave #closing (set above) — do NOT revert to #open, which the 60s expiry
          // timer would re-select and retry every tick. Park for recovery instead.
          return #settlementFailed("EVM sender not configured (ecdsaKeyName missing)");
        };
      };

      // Settle consumed amount to recipient.
      // B2: confirm the transfer mined (status==1) before treating it as settled — a mempool
      // ack is NOT finality. Finalize (#closed) only on #confirmed; otherwise stay parked in
      // #closing (set above) for recovery and NEVER re-broadcast (a #pending tx may have landed,
      // so re-driving double-pays).
      var settleTxHash : ?Text = null;
      if (session.consumed > 0) {
        switch (
          await sender.sendErc20TransferConfirmed(
            deposit.chainId, deposit.tokenAddress, session.recipient, session.consumed, 4,
          )
        ) {
          case (#confirmed(hash)) { settleTxHash := ?hash };
          case (#reverted(hash)) {
            // Mined but reverted — no funds moved. Park in #closing; do NOT mark #closed.
            return #settlementFailed("EVM settle reverted on-chain (session parked for recovery; tx " # hash # ")");
          };
          case (#pending(hash)) {
            // Broadcast but not confirmed — it MAY have landed; park for confirm-only recovery.
            closeParkedTxs.put(session.id, { leg = #Settle; txHash = hash });
            return #settlementPending("EVM settle broadcast but not confirmed (session parked — reconcileSession; tx " # hash # ")");
          };
          case (#err(msg)) {
            // M10: pre-broadcast #err means NOTHING was broadcast for this session (safe to roll
            // back — no funds moved, consumed unsettled). For a CLIENT-initiated close, restore
            // #open so the session stays usable and the client can retry; otherwise a transient
            // reject (e.g. a concurrent tx holding the EvmSender single-flight lock — the M10
            // race) would strand it permanently in #closing with no retry path. For a
            // timer-initiated (expired) close, keep #closing to avoid the 60s expiry timer
            // re-driving a persistent failure every tick (S16/C1).
            if (not wasExpired) {
              session.status := #open;
              return #settlementFailed("EVM settle failed — nothing broadcast, session reopened (safe to retry): " # msg);
            };
            return #settlementFailed("EVM settle failed (session parked for recovery): " # msg);
          };
        };
      };

      // Refund remainder to payer (no ledger fees to subtract for EVM — gas is in ETH)
      var refundTxHash : ?Text = null;
      let refunded = Utils.satSub(session.deposited, session.consumed);

      if (refunded > 0) {
        switch (
          await sender.sendErc20TransferConfirmed(
            deposit.chainId, deposit.tokenAddress, deposit.payerEvmAddress, refunded, 4,
          )
        ) {
          case (#confirmed(hash)) { refundTxHash := ?hash };
          case (#reverted(hash)) {
            // C-1: settle confirmed but refund reverted — leave #closing so the unconsumed
            // funds are not silently discarded. Recovery for an EVM session is MANUAL (an
            // admin re-drives the refund / re-polls; recoverEscrow handles ICP escrow only,
            // not the shared EVM balance). Do NOT mark #closed.
            return #settlementFailed("EVM refund reverted on-chain (settle succeeded, session left in #closing; tx " # hash # ")");
          };
          case (#pending(hash)) {
            // Broadcast but not confirmed — park in #closing; the refund may have landed,
            // so recovery must re-poll the hash rather than re-broadcast.
            closeParkedTxs.put(session.id, { leg = #Refund; txHash = hash });
            return #settlementPending("EVM refund broadcast but not confirmed (settle succeeded, session parked — reconcileSession; tx " # hash # ")");
          };
          case (#err(msg)) {
            // M10: refund failed pre-broadcast (nothing broadcast). If settle ran and confirmed
            // (settleTxHash set), we must NOT reopen — a retry would re-settle consumed; park in
            // #closing. If settle was SKIPPED (consumed == 0, nothing moved at all), a
            // client-initiated close can safely reopen to #open and retry.
            if (settleTxHash == null and not wasExpired) {
              session.status := #open;
              return #settlementFailed("EVM refund failed — nothing broadcast, session reopened (safe to retry): " # msg);
            };
            return #settlementFailed("EVM refund failed (settle succeeded, session left in #closing): " # msg);
          };
        };
      };

      // Deallocate from EVM escrow
      ignore evmEscrowManager.deallocate(session.id);

      // S-3: A successful EVM close is TERMINAL. The expiry timer sets #expired BEFORE
      // calling close, so ending in #expired again leaves the session in a state the
      // re-close guard (closeSessionInternal) does NOT reject — letting the payer trigger
      // a SECOND on-chain settle+refund from the canister's shared EVM balance and drain
      // other payers' pooled deposits. End in #closed so any re-close is rejected.
      // (ICP sessions don't need this: the per-session subaccount is already drained, so a
      // second settle/refund fails with InsufficientFunds.)
      session.status := #closed;
      closeParkedTxs.delete(session.id); // close fully succeeded — clear any prior park

      // M-9 (v2): Credit the unused deposit back against the daily limit.
      if (session.deposited > session.consumed) {
        policy.releaseDaily(session.payer, session.spendDay, session.deposited - session.consumed);
      };

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
          let maxRecoverable = Utils.satSub(session.deposited, session.consumed);
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
          spendDay = policy.currentDay();
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
