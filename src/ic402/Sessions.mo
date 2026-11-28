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
import Int "mo:base/Int";
import Nat64 "mo:base/Nat64";
import Text "mo:base/Text";
import HashMap "mo:base/HashMap";
import Iter "mo:base/Iter";
import Array "mo:base/Array";
import Nat8 "mo:base/Nat8";
import Principal "mo:base/Principal";
import Blob "mo:base/Blob";
import Error "mo:base/Error";
import CBOR "mo:cbor";
import Ed25519 "Ed25519";
import Identity "Identity";
import Debug "mo:base/Debug";
import Timer "mo:base/Timer";

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

  // 2.17.0: a key ANYONE can sign as. The IC checks ingress signatures cofactored (ZIP-215), which
  // accepts forgeries under a small-order key, so its self-authenticating principal proves nothing.
  // y (sign bit dropped) ∈ {0, 1, p − 1, ±y8} is small order; y ≥ p is non-canonical (refused too).
  func smallOrderKey(key : Blob) : Bool {
    let y = Array.foldRight<Nat8, Nat>(Blob.toArray(key), 0, func(b, acc) = acc * 256 + Nat8.toNat(b)) % (2 ** 255);
    let p = 57896044618658097711785492504343953926634992332820282019728792003956564819949; // 2^255 − 19
    let y8 = 2707385501144840649318225287225658788936804267575313519463743609750303402022; // order 8
    y <= 1 or y + 1 >= p or y == y8 or y + y8 == p; // y + y8 == p: y == −y8, without a Nat subtraction
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
  /// 2.22.0 (F1): #dropped — the parked tx appears not to have landed (no receipt, and its nonce
  /// was used by another tx) — is REPORTED, not acted on: the session stays parked and the
  /// operator verifies on chain before forcing. Providers can lag, so it is never proof.
  public func sessionReconcileDecision(
    outcome : { #confirmed; #reverted; #pending; #dropped : Text; #err : Text },
    leg : { #Settle; #Refund },
    refundOwed : Nat,
  ) : SessionReconcileResult {
    switch (outcome) {
      case (#pending) { #stay("Parked close tx still pending — stay parked") };
      case (#dropped(why)) {
        let owed = switch (leg) {
          case (#Settle) { "the consumed amount to the recipient and the remainder to the payer" };
          case (#Refund) { "the remainder to the payer" };
        };
        #stay("Parked " # (switch (leg) { case (#Settle) { "settle" }; case (#Refund) { "refund" } }) # " tx appears not to have landed (" # why # ") — verify on chain before forcing. Only if a block explorer shows it never landed: forceResolveSession, then sweepEvm what is owed: " # owed);
      };
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

  /// 2.22.0: the idle timeout a new session gets. The client's own value may only shorten the
  /// operator's: with a policy sessionIdleTimeout set, the session gets the smaller of the two (a
  /// client could otherwise keep an idle session, and its deposit and concurrency slot, open past
  /// the operator's limit). No client value inherits the policy's; no policy value keeps the client's.
  public func effectiveIdleTimeout(client : ?Int, policyTimeout : ?Int) : ?Int {
    switch (client, policyTimeout) {
      case (?c, ?p) { ?Int.min(c, p) };
      case (?c, null) { ?c };
      case (null, p) { p };
    };
  };

  /// 2.22.0: whether an EVM close whose leg failed BEFORE anything was broadcast reopens the
  /// session (#open) — only when no leg of this close moved funds (`nothingMoved`), and either
  /// the payer asked for the close or the failure was refused before signing and clears without
  /// the caller (EvmSender.sendCanWait): the busy single-flight send lock, or (2.23.2) a gas stop.
  /// A timer-initiated close that fails for another reason stays #closing, so the 60 s sweep does
  /// not re-drive a persistent failure every tick (S16/C1); before 2.22.0 that included the busy
  /// lock, which parked an expired session with no tx to reconcile. The send that set a gas stop
  /// never reaches this rule: it was signed, and a provider may have accepted it, so the close
  /// parks that leg with its hash (EvmSender.gasRefusedTxHash). A gas-stopped chain is re-driven
  /// with no outcall or signature (the stop refuses first), and the session closes by itself once
  /// the stop ends or is lifted.
  public func reopenAfterUnsentLeg(wasExpired : Bool, nothingMoved : Bool, err : Text) : Bool {
    nothingMoved and (not wasExpired or EvmSender.sendCanWait(err));
  };

  /// 2.22.0: the token an ICP session opened with `intentToken` (resolved to `ledger`) stores: "icp:*"
  /// as given, anything else as the ledger's principal text. A token matched by its configured
  /// SYMBOL must not be stored as the symbol: a close reads a stored symbol as a pre-2.22.0 session,
  /// whose deposit is on tokens[0] (Utils.findSessionLedger).
  public func storedSessionToken(intentToken : Text, ledger : Principal) : Text {
    if (Text.startsWith(intentToken, #text "icp:")) { intentToken } else { Principal.toText(ledger) };
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
    // 2.18.0: ICP sessions whose close failed its refund leg — the payer's remainder is still in escrow
    // (Types.RefundOwed). Reported by sessionCounts().refundOwed, and gcClosedSessions keeps their record
    // (it is what authorizes recoverEscrow) until the payer has recovered. Kept outside StableSession so
    // no stored type changes: persisted through refundOwedToStable / loadRefundOwed.
    // 2.22.0: every ICP path that ends #closed with payer funds left in escrow writes one (the close's
    // failed refund, reconcileSession, forceResolveSession), and recoverEscrow pays an ICP session only
    // against its entry, never more than it: the entry is the payer's whole claim on the escrow.
    var refundOwed = HashMap.HashMap<Text, { escrow : Nat; fee : Nat }>(8, Text.equal, Text.hash);
    // Recovery: a session whose EVM close settle/refund parked (#pending) records the parked leg
    // + tx hash here so reconcileSession can re-poll it confirm-only. Transient (not in
    // StableSession; a parked session mid-upgrade falls under the B1 fresh-deploy waiver).
    let closeParkedTxs = HashMap.HashMap<Text, { leg : { #Settle; #Refund }; txHash : Text }>(8, Text.equal, Text.hash);
    // The txHash of a parked leg whose send call was rejected without reporting a hash: it may have
    // been broadcast (parkRejectedLeg). reconcileSession never polls it.
    let HASH_UNKNOWN : Text = "";
    // 2.20.0: ICP closes currently between their awaits. reconcileSession reads the escrow balance
    // of a session left #closing by an unknown settle reject, and must never do so while a close is
    // still moving that escrow. Transient on purpose: Motoko refuses an upgrade while callbacks are
    // outstanding (canister_pre_upgrade traps and install_code is atomic), so no ledger call outlives
    // an upgrade and the set is empty afterwards. A close that traps after an await still runs the
    // `finally` and clears its entry; a trap before the first await rolls the entry back with it.
    let icpClosesInFlight = HashMap.HashMap<Text, ()>(8, Text.equal, Text.hash);
    // 2.22.0: the same for EVM closes, which park #closing between their sends. reconcileSession and
    // forceResolveSession refuse while one is in flight: a force landing mid-close let a close that
    // then failed before broadcast reopen the finalized session. Transient for the same reason.
    let evmClosesInFlight = HashMap.HashMap<Text, ()>(8, Text.equal, Text.hash);
    // 2.22.0: recoverEscrow calls between their awaits. One recovery per session at a time, so two
    // concurrent calls cannot both be capped by the same refundOwed entry before either has reduced
    // it. Transient for the same reason as icpClosesInFlight.
    let recoveriesInFlight = HashMap.HashMap<Text, ()>(8, Text.equal, Text.hash);
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
    // 2.22.0: authNonce (transient record only) lets reconcileEvmDeposit read the authorization's state.
    type PendingEvmDeposit = { payer : Principal; payerEvmAddress : Text; chainId : Nat; token : Text; amount : Nat; createdAt : Int; authNonce : Blob };
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

    // 2.22.0 (E3): where every EVM path here gets its sender — read at each use, never captured.
    // Defaults to the constructor's `evmSender`; the Gateway injects a getter of its CURRENT
    // sender, which setEvmDerivationPath replaces.
    var evmSenderSource : () -> ?EvmSender.EvmSender = func() : ?EvmSender.EvmSender { evmSender };
    /// Read the EVM sender through `f` from now on (injected by the Gateway).
    public func setEvmSenderSource(f : () -> ?EvmSender.EvmSender) { evmSenderSource := f };

    // Live EVM chain set consulted by openEvmSession's chain lookup. Starts as the constructor
    // config's evmChains; replaced at runtime via setEvmChains. Motoko records are immutable
    // value bindings, so this class holds its OWN copy of the chain list — a Gateway that only
    // mutated its own binding would silently leave the session-open path on the construction-time
    // chains. Gateway.setEvmChains therefore updates BOTH in the same call. Transient like
    // setAdmitRate/setPolicy: reverts to the constructor config on upgrade.
    var liveEvmChains : [Types.EvmChainConfig] = config.evmChains;

    /// Replace the EVM chain set for session opens (injected by Gateway.setEvmChains — call
    /// directly only if you constructed this Sessions instance yourself). Open sessions are
    /// unaffected: close/reconcile/park use session-stored fields, not this list.
    public func setEvmChains(chains : [Types.EvmChainConfig]) { liveEvmChains := chains };

    // Opt-in caller binding for ICP-rail sessions (see setRequireCallerBoundSessions). Transient
    // by design — an operator-init setting like setAdmitRate/setPolicy, re-applied on upgrade.
    var requireCallerBoundSessions : Bool = false;

    /// Opt-in (default OFF): require an ICP-rail session's Ed25519 voucher key to be the CALLER'S
    /// OWN IC identity key — sha224(DER-SPKI(key)) ‖ 0x02 must equal the caller principal — so a
    /// relying party can conclude the principal that opened (and paid for) a session is the one
    /// whose key signs its vouchers. Leave OFF unless every session client authenticates with a
    /// raw Ed25519 identity: Internet Identity delegations and secp256k1/P-256 identities derive
    /// different principals and would be rejected. ICP rail only — an EVM session's payer identity
    /// is the on-chain EVM address (authz.from), not msg.caller, so caller binding does not apply.
    public func setRequireCallerBoundSessions(on : Bool) { requireCallerBoundSessions := on };

    /// 2.17.0 (default ON, for older clients): accept signed vouchers from callers other than the
    /// session key, bare consumeVoucher included (see consumeVoucherFrom). Transient — re-apply at init.
    var signedVoucherFallback : Bool = true;
    public func setSignedVoucherFallback(on : Bool) { signedVoucherFallback := on };

    /// Whether a session's registered voucher key is the payer's OWN IC identity key (Ed25519
    /// self-authenticating principal check — Identity.selfAuthPrincipalOfEd25519). Derived from
    /// stored state, so it also answers for sessions opened before this method existed. null = no
    /// such session. false means "not identity-bound" (an ephemeral or delegated voucher key, or a
    /// non-Ed25519 caller identity) — it never means the session is invalid; EVM-rail sessions are
    /// typically false because their voucher key is session-ephemeral.
    public func sessionCallerBound(sessionId : Text) : ?Bool {
      switch (sessions.get(sessionId)) {
        case (?s) { ?(Identity.selfAuthPrincipalOfEd25519(s.payerPublicKey) == ?Principal.toBlob(s.payer)) };
        case (null) { null };
      };
    };

    func findLedger(identifier : Text) : ?Types.TokenConfig {
      Utils.findLedger(config.tokens, identifier);
    };

    // The ledger holding a stored ICP session's escrow (Utils.findSessionLedger: legacy tokens that
    // are not a principal resolve to tokens[0], as 2.21.0 opened them; an unconfigured principal fails
    // closed). For close, reconcileSession and recoverEscrow — never for a new open.
    func findSessionLedger(stored : Text) : ?Types.TokenConfig {
      Utils.findSessionLedger(config.tokens, stored);
    };

    func recipientAccount() : Types.Account {
      { owner = config.recipient.owner; subaccount = config.recipient.subaccount };
    };

    /// Count active sessions for a caller (for maxConcurrentSessions). 2.22.0: an ICP session parked
    /// #closing with nothing consumed counts too: it is a deposit parked at open, which
    /// reconcileSession may open, so leaving it out let the payer open another meanwhile and end up
    /// over the limit.
    func activeSessionCount(caller : Principal) : Nat {
      var count = 0;
      for ((_, s) in sessions.entries()) {
        if (Principal.equal(s.payer, caller) and (s.status == #open or (s.status == #closing and s.consumed == 0 and not isEvmNetwork(s.network)))) {
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
    /// ICP (2.21.0): the ledger's fee is queried first; if it cannot be (a stopped ledger), the open
    /// is refused with #settlementFailed and nothing moves. If the deposit call itself is then
    /// rejected with an unknown outcome, returns #err(#settlementPending(...)) and the session
    /// EXISTS, parked #closing with nothing consumed, for the controller's reconcileSession.
    /// ICP (2.22.0): intent.token must be a configured ledger's principal text, its symbol, or
    /// "icp:*" (anything else is #tokenNotAccepted, nothing moved); a symbol is stored, and shown on
    /// the close receipt, as that ledger's principal text.
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

      // Find ledger. 2.22.0: the intent's token must resolve (principal text, a configured symbol, or
      // "icp:*"), no fallback to tokens[0] for anything else.
      let tokenConfig = switch (findLedger(intent.token)) {
        case (?tc) { tc };
        case (null) {
          sessionOpenLocks.delete(caller);
          if (config.tokens.size() == 0) { return #err(#tokenNotAccepted("No accepted token configured")) };
          return #err(#tokenNotAccepted("Session token " # intent.token # " is not a configured ledger: use the ledger's principal text (or the network, e.g. \"icp:1\") as the intent's token. Nothing moved."));
        };
      };

      let ledger : Types.LedgerActor = actor (Principal.toText(tokenConfig.ledger));
      // 2.22.0: what the session stores as its token (storedSessionToken): a symbol becomes its
      // ledger's principal text. Nothing signs over the token; the close receipt's `token` is this
      // text (a ledger principal, as on an ICP charge receipt).
      let sessionToken = storedSessionToken(intent.token, tokenConfig.ledger);

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
      if (Blob.toArray(sessionPublicKey).size() != 32 or smallOrderKey(sessionPublicKey)) {
        sessionOpenLocks.delete(caller);
        return #err(#invalidSignature("Public key must be a 32-byte Ed25519 key, not a small-order point (anyone can sign as one)"));
      };
      // Opt-in caller binding (setRequireCallerBoundSessions): the voucher key must BE the
      // caller's own IC identity key. Checked here — before the deposit pull — so a rejection
      // moves no funds. Reuses #invalidSignature (no new variant) with an actionable message.
      if (requireCallerBoundSessions and Identity.selfAuthPrincipalOfEd25519(sessionPublicKey) != ?Principal.toBlob(caller)) {
        sessionOpenLocks.delete(caller);
        return #err(#invalidSignature("Session public key is not the caller's own identity key (its Ed25519 self-authenticating principal does not match the caller) — this canister requires caller-bound sessions. Sign vouchers with the same raw Ed25519 key the caller authenticates with; Internet Identity delegations and secp256k1/P-256 identities cannot satisfy this check."));
      };

      // The session record, for a normal open and for a deposit parked by an unknown reject.
      func sessionRecord(status : Types.SessionStatus, effectivePolicy : Policy.SpendingPolicy) : Types.InternalSessionState {
        let now = Time.now();
        {
          id = sessionId;
          payer = caller;
          payerPublicKey = sessionPublicKey;
          deposited = deposit;
          spendDay = policy.currentDay();
          var consumed = 0;
          var remaining = deposit;
          var voucherCount = 0;
          var status = status;
          openedAt = now;
          var lastActivityAt = now;
          var lastSequence = 0;
          var lastCumulativeAmount = 0;
          subaccount;
          network = intent.network;
          token = sessionToken;
          recipient = intent.recipient;
          autoClose = clientConfig.autoClose;
          maxDuration = effectivePolicy.maxSessionDuration;
          idleTimeout = effectiveIdleTimeout(clientConfig.idleTimeout, effectivePolicy.sessionIdleTimeout);
          evmDeposit = null; // ICP session
        };
      };

      // 2.21.0: ask the ledger for its fee before pulling the deposit. The query moves nothing, so if
      // it fails (most often a ledger stopped for an upgrade) the open is refused cleanly instead of
      // the deposit's reject parking a session. Parking is then left to the rare reject that follows
      // a fee query that succeeded.
      try { ignore await ledger.icrc1_fee() } catch (e) {
        sessionOpenLocks.delete(caller);
        return #err(#settlementFailed("Ledger fee query failed before the deposit (nothing moved; safe to retry): " # Error.message(e)));
      };

      // Execute deposit via escrow. Inline (`await*`, 2.21.0), so a ledger reject arrives here with
      // the ledger's own reject code.
      let depositResult = try {
        await* escrowManager.depositCore(
          ledger,
          { owner = caller; subaccount = null },
          deposit,
          subaccount,
        );
      } catch (e) {
        if (Utils.rejectedBeforeExecution(Error.code(e))) {
          sessionOpenLocks.delete(caller);
          return #err(#settlementFailed("Deposit call failed before the ledger ran (nothing moved; safe to retry): " # Error.message(e)));
        };
        // 2.21.0: any other reject leaves the deposit's outcome UNKNOWN: it may be in this session's
        // escrow. Before, the reject escaped openSession and no session record existed, so a deposit
        // that had landed could not be recovered in-band. Park the session #closing with nothing
        // consumed: vouchers and closes refuse it, the expiry sweep skips it, and reconcileSession
        // reads the escrow balance to decide (the deposit is there: open; it is not: close, with
        // nothing owed). The expiry timer keeps ticking while it is parked (hasExpiryWork). The daily reservation is held until then, as for an open session.
        let parked = sessionRecord(#closing, policy.getEffectivePolicy(caller));
        sessions.put(sessionId, parked);
        armExpiryTimer<system>();
        policy.recordSpend(caller, deposit);
        sessionOpenLocks.delete(caller);
        return #err(#settlementPending("Deposit rejected (" # debug_show (Error.code(e)) # "): its outcome is UNKNOWN — it may be in escrow. Session " # sessionId # " is parked #closing. Once the ledger is reachable, the canister's controller runs reconcileSession(\"" # sessionId # "\"): it reads the escrow balance and either opens the session (the deposit landed) or closes it with nothing owed (it did not). Do not open another session for this deposit meanwhile. " # Error.message(e)));
      };

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
            let _refundResult = await* escrowManager.refundCore(
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
      let session = sessionRecord(#open, effectivePolicy);

      sessions.put(sessionId, session);
      // Self-arming expiry: this is a session-CREATING path, so it owns an arm site (see the
      // expiry timer contract above). Free here — openSession is async, so the `system`
      // capability is available without changing any signature.
      armExpiryTimer<system>();
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
      // 2.22.0: as Gateway.settle — refuse fields the chain could not hold (they would be encoded
      // truncated) and an authorization outside its window (validBefore strict, as on chain). The
      // open path had no window check, so an expired deposit authorization was broadcast and
      // reverted at the canister's gas.
      let fromBytes = EvmUtils.hexToBytes(authz.from);
      let authNonceBytes = Blob.toArray(authz.nonce);
      if (not EvmUtils.eip3009FieldsFit(authz.value, authz.validAfter, authz.validBefore, authNonceBytes)) {
        sessionOpenLocks.delete(caller);
        return #err(#invalidSignature("EIP-3009 authorization fields out of range: value, validAfter and validBefore must fit uint256 and the nonce must be 32 bytes"));
      };
      let nowSeconds = Int.abs(Time.now() / 1_000_000_000);
      if (nowSeconds < authz.validAfter) { sessionOpenLocks.delete(caller); return #err(#expired("Authorization not yet valid")) };
      // 2.23.1: and it must stay valid long enough to land (EvmSender.MIN_VALIDITY_SECONDS).
      if (EvmSender.expiresTooSoon(authz.validBefore, nowSeconds)) { sessionOpenLocks.delete(caller); return #err(#expired(EvmSender.EXPIRES_TOO_SOON)) };

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
        // First match wins (same order as Gateway.findEvmChain; setEvmChains rejects duplicates
        // anyway, but the two rails must never resolve the same chainId differently).
        for (c in liveEvmChains.values()) { if (found == null and c.chainId == chainId) found := ?c };
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
      // STRICT membership (parity with Gateway.settle's resolveEvmDomain): an unconfigured token
      // must NOT fall through to the "USD Coin"/"2" default domain — for canonical USDC that
      // default VERIFIES, so a token removed via setEvmChains could otherwise still open new
      // sessions. First match wins, as in Gateway.resolveEvmDomain.
      var tokenConfigured = false;
      for (tok in evmChain.tokens.values()) {
        if ((not tokenConfigured) and EvmUtils.addressesEqual(tok.address, tokenAddr)) {
          tokenName := tok.name;
          tokenVersion := tok.version;
          tokenConfigured := true;
        };
      };
      if (not tokenConfigured) {
        sessionOpenLocks.delete(caller);
        return #err(#invalidSignature("Unsupported asset " # tokenAddr # " on chain " # Nat.toText(chainId) # " — not in the chain's configured token list (it may have been removed via setEvmChains); request a fresh session intent"));
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
      if (Blob.toArray(sessionPublicKey).size() != 32 or smallOrderKey(sessionPublicKey)) {
        sessionOpenLocks.delete(caller);
        return #err(#invalidSignature("Public key must be a 32-byte Ed25519 key, not a small-order point (anyone can sign as one)"));
      };

      let verified = Eip712.verifyAuthorization(
        chainId, EvmUtils.hexToBytes(tokenAddr),
        fromBytes, EvmUtils.hexToBytes(authz.to),
        authz.value, authz.validAfter, authz.validBefore,
        authNonceBytes, authz.v,
        Blob.toArray(authz.r), Blob.toArray(authz.s),
        tokenName, tokenVersion,
      );
      if (not verified) {
        sessionOpenLocks.delete(caller);
        return #err(#invalidSignature("EIP-3009 authorization signature verification failed — the signature is not in the form USDC accepts on chain (low s, v of 27/28), or the recovered signer does not match authorization.from. Check the EIP-712 domain matches this canister's config (token name/version, chainId, verifyingContract = the paid asset) and that the signer key controls the from address. Not retryable without re-signing."));
      };

      // Execute transferWithAuthorization via tECDSA (canister acts as facilitator)
      let sender = switch (evmSenderSource()) {
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

      // 2.22.0 (E5): never broadcast one authorization twice (EvmSender.AuthorizationGuard, shared
      // with Gateway.settle through the one sender). Claimed before the await; kept if the call
      // throws (whether it broadcast is unknown), released on a pre-broadcast #err.
      let authKey = sender.broadcastAuthorizations.key(chainId, intent.token, fromBytes, authNonceBytes);
      switch (sender.broadcastAuthorizations.claim(authKey, authz.validBefore, nowSeconds)) {
        case (#seen(prior)) {
          ignore evmEscrowManager.deallocate(sessionId);
          sessionOpenLocks.delete(caller);
          return #err(#settlementPending(EvmSender.alreadyBroadcastText(prior)));
        };
        case (#ok) {};
      };

      // 2.23.1: one inbound transfer in flight per payer (chain, token, from), shared with
      // Gateway.settle through the one sender — see EvmSender.PayerGuard. Claimed after the
      // signature verified; released however this open returns.
      // Refused while that payer cools down after a sent transfer reverted, or is held while one
      // had not confirmed (PayerGuard.coolDown).
      let payerKey = sender.inFlightPayers.key(chainId, intent.token, fromBytes);
      switch (sender.inFlightPayers.claim(payerKey, nowSeconds)) {
        case (#ok) {};
        case (refused) {
          sender.broadcastAuthorizations.release(authKey); // not sent, so it may be sent later
          ignore evmEscrowManager.deallocate(sessionId);
          sessionOpenLocks.delete(caller);
          return #err(#policyDenied(switch (refused) { case (#coolingDown(until)) { EvmSender.payerCoolingText(until) }; case (_) { EvmSender.PAYER_BUSY } }));
        };
      };

      try {
        let execResult = try {
          await sender.executeTransferWithAuthorization(
            chainId, intent.token,
            fromBytes,
            EvmUtils.hexToBytes(authz.to),
            authz.value, authz.validAfter, authz.validBefore,
            authNonceBytes,
            authz.v, Blob.toArray(authz.r), Blob.toArray(authz.s),
          );
        } catch (e) {
          // H3: no session — release the reservation. Round 2: whether the call broadcast is unknown
          // (the E5 claim is kept for that reason), so this is pending, not "failed, nothing moved".
          // 2.23.1: hold the payer while it may still land (PayerGuard.coolDown).
          sender.inFlightPayers.coolDown(payerKey, Int.abs(Time.now() / 1_000_000_000), EvmSender.UNCONFIRMED_HOLD_SECONDS);
          ignore evmEscrowManager.deallocate(sessionId);
          sessionOpenLocks.delete(caller);
          return #err(#settlementPending("EIP-3009 deposit call failed and whether it was broadcast is unknown: " # Error.message(e) # ". No session was created. The deposit may still land — do NOT re-sign; this authorization will not be broadcast again. The operator checks the chain for payer " # authz.from # "'s authorization and returns the deposit (sweepEvm) if it arrived."));
        };

        let depositTxHash = switch (execResult) {
          case (#ok(hash)) { hash };
          case (#err(msg)) {
            sender.broadcastAuthorizations.release(authKey); // nothing was broadcast
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
        sender.broadcastAuthorizations.noteTx(authKey, depositTxHash);

        // H-1 (v2): Confirm the deposit transfer actually mined before crediting an
        // escrow allocation. Otherwise a reverted/never-mined deposit would still
        // open a funded session whose refund is drawn from the canister's balance.
        // 2.22.0: a rejected confirm call is "confirmation unavailable" (#err), as in Gateway.settleCore:
        // the deposit was broadcast, so it must be tracked, not left with the open lock held.
        let depositConfirmation = try { await sender.confirmTransaction(chainId, depositTxHash, 4) } catch (e) {
          #err(Error.message(e));
        };
        switch (depositConfirmation) {
          case (#confirmed) {};
          case (#reverted) {
            // H3: no session — release the reservation. 2.22.0 (E7): THIS tx reverting does not mean
            // the deposit did not arrive: anyone can submit the authorization, so another tx may have
            // executed it first. Ask the token before answering. 2.23.1: it passed the simulation and
            // reverted on chain — hold the payer now, and cool it down for the hour below unless
            // another transaction executed the authorization (#used) (PayerGuard.coolDown).
            sender.inFlightPayers.coolDown(payerKey, Int.abs(Time.now() / 1_000_000_000), EvmSender.UNCONFIRMED_HOLD_SECONDS);
            ignore evmEscrowManager.deallocate(sessionId);
            sessionOpenLocks.delete(caller);
            // A rejected check is "could not be checked" (#unknown), as in Gateway.settleCore.
            let depositAuthState = try { await sender.authorizationState(chainId, intent.token, fromBytes, authNonceBytes) } catch (e) {
              #unknown(Error.message(e));
            };
            switch (depositAuthState) {
              case (#unused) {
              sender.inFlightPayers.coolDown(payerKey, Int.abs(Time.now() / 1_000_000_000), EvmSender.REVERT_COOLDOWN_SECONDS);
              return #err(#settlementFailed("EVM deposit reverted on-chain (tx " # depositTxHash # ") with the authorization unused: no funds moved. Payments from this payer are refused for an hour."));
            };
              case (#used) {
                return #err(#settlementPending("EVM deposit tx " # depositTxHash # " reverted, but the deposit authorization is already used on chain: another transaction executed it (anyone can submit it) or the payer cancelled it. The deposit may be in the canister's pool; no session was created. Payments from this payer are refused for 5 minutes. Do NOT re-sign — the operator checks the chain for payer " # authz.from # "'s authorization and returns the deposit (sweepEvm) if it arrived."));
              };
              case (#unknown(e)) {
                sender.inFlightPayers.coolDown(payerKey, Int.abs(Time.now() / 1_000_000_000), EvmSender.REVERT_COOLDOWN_SECONDS);
                return #err(#settlementPending("EVM deposit tx " # depositTxHash # " reverted, and whether another transaction executed the deposit authorization could not be checked (" # e # "). The deposit may be in the canister's pool; no session was created. Payments from this payer are refused for an hour. Do NOT re-sign until the token's authorizationState for payer " # authz.from # " shows it unused."));
              };
            };
          };
          case (#pending) {
            // H3: release the pool reservation so it does not leak headroom. M8: track the
            // broadcast-but-unconfirmed deposit so it can be reconciled (refunded) if it later mines,
            // instead of stranding unattributed in the shared pool.
            sender.inFlightPayers.coolDown(payerKey, Int.abs(Time.now() / 1_000_000_000), EvmSender.UNCONFIRMED_HOLD_SECONDS); // 2.23.1
            ignore evmEscrowManager.deallocate(sessionId);
            pendingEvmDeposits.put(depositTxHash, { payer = caller; payerEvmAddress = authz.from; chainId; token = intent.token; amount = deposit; createdAt = Time.now(); authNonce = authz.nonce });
            sessionOpenLocks.delete(caller);
            return #err(#settlementPending("EVM deposit broadcast but not yet confirmed (tx " # depositTxHash # ") — no session was created. If the tx mines, the deposit lands in the shared pool: call reconcileEvmDeposit with this tx hash to refund it, then open a new session (payments from this payer are refused for 5 minutes meanwhile). Do not re-sign the same authorization."));
          };
          case (#err(e)) {
            // H3: release reservation. M8: track for reconcile (see #pending).
            sender.inFlightPayers.coolDown(payerKey, Int.abs(Time.now() / 1_000_000_000), EvmSender.UNCONFIRMED_HOLD_SECONDS); // 2.23.1
            ignore evmEscrowManager.deallocate(sessionId);
            pendingEvmDeposits.put(depositTxHash, { payer = caller; payerEvmAddress = authz.from; chainId; token = intent.token; amount = deposit; createdAt = Time.now(); authNonce = authz.nonce });
            sessionOpenLocks.delete(caller);
            return #err(#settlementPending("EVM deposit broadcast; confirmation unavailable: " # e # " (tx " # depositTxHash # ") — no session was created; the deposit is tracked. Retry reconcileEvmDeposit with this tx hash once the RPC recovers (refund-on-confirm). Payments from this payer are refused for 5 minutes meanwhile."));
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
          idleTimeout = effectiveIdleTimeout(clientConfig.idleTimeout, effectivePolicy.sessionIdleTimeout);
          evmDeposit = ?{
            txHash = depositTxHash;
            chainId;
            payerEvmAddress = authz.from;
            tokenAddress = intent.token;
          };
        };

        sessions.put(sessionId, session);
        // Self-arming expiry: second of the two session-CREATING paths (see the contract above).
        armExpiryTimer<system>();
        policy.recordSpend(caller, deposit);
        sessionOpenLocks.delete(caller);

        #ok(toPublic(session));
      } finally {
        sender.inFlightPayers.release(payerKey);
      };
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
    /// Deprecated (2.17.0): prefer consumeVoucherFrom; this path always runs the signature check
    /// while the fallback is on, and refuses every voucher once setSignedVoucherFallback(false).
    public func consumeVoucher(voucher : Types.Voucher) : Types.VoucherResult {
      consumeWith(null, voucher);
    };

    /// 2.17.0: consumeVoucher with the submitting principal (pass msg.caller). When `caller` is the
    /// session key's self-authenticating principal (Identity.selfAuthPrincipalOfEd25519), the IC has
    /// already verified the call, so the voucher is accepted on state, sequence, amount and policy
    /// alone: no Ed25519 check, `voucher.signature` unread (never for a small-order key, which anyone
    /// can sign as). Other callers take the signed path while setSignedVoucherFallback is on
    /// (default); off, they get #invalidSignature right after the session lookup.
    public func consumeVoucherFrom(caller : Principal, voucher : Types.Voucher) : Types.VoucherResult {
      consumeWith(?caller, voucher);
    };

    func consumeWith(caller : ?Principal, voucher : Types.Voucher) : Types.VoucherResult {
      let session = switch (sessions.get(voucher.sessionId)) {
        case (null) { return #sessionNotOpen };
        case (?s) { s };
      };

      // 2.17.0: refuse a non-key caller first when the fallback is off, so a stranger learns no
      // session state and spends neither the payer's rate slot nor a signature check. A small-order
      // key is never "the key" (open refuses one; this covers sessions opened before 2.17.0).
      let callerIsKey = switch (caller) {
        case (?c) { Identity.selfAuthPrincipalOfEd25519(session.payerPublicKey) == ?Principal.toBlob(c) and not smallOrderKey(session.payerPublicKey) };
        case (null) { false };
      };
      if (not callerIsKey and not signedVoucherFallback) return #invalidSignature;

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

      // Ed25519 signature verification — only when the caller is not the session key itself
      if (not callerIsKey) {
        // H-2: Handle Nat64 overflow gracefully instead of trapping
        // M-7: Bind the verifying canister's principal into the signed payload.
        let payload = switch (encodeVoucherPayload(Principal.toText(canisterPrincipal), voucher.sessionId, voucher.cumulativeAmount, voucher.sequence)) {
          case (?p) { p };
          case (null) { return #payloadOverflow };
        };
        if (voucher.signature.size() != 64) { return #invalidSignature };
        if (session.payerPublicKey.size() != 32) { return #invalidSignature };

        // Total (never traps) and RFC 8032-strict — see src/ic402/Ed25519.mo.
        if (not Ed25519.verify(voucher.signature, Blob.fromArray(payload), session.payerPublicKey)) {
          return #invalidSignature;
        };
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
    /// ICP: ledger fees come out of the refund (refunded = deposited − consumed − fees). A settle
    /// the ledger refuses (#Err), or a reject the system raised before the ledger ran, reopens the
    /// session (#settlementFailed("Settle: …")). 2.20.0: any other reject leaves the outcome
    /// unknown, so the session stays #closing and #settlementPending is returned; reconcileSession
    /// resolves it from the escrow balance. If the refund leg then fails or is rejected, the
    /// session is still marked #closed and
    /// #settlementFailed("Refund leg failed/rejected (session marked #closed): …") is returned —
    /// the remainder stays in the escrow subaccount and is recoverable via recoverEscrow.
    /// 2.22.0: a session token naming a ledger that is no longer configured is refused before
    /// anything moves (#settlementFailed; the session is left #open), never closed on tokens[0].
    /// Any other unconfigured token (a pre-2.22.0 symbol or other text) closes on tokens[0], where
    /// 2.21.0 opened it (Utils.findSessionLedger).
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
        return #settlementFailed("Session already closed or a close is in progress (#closing) — do not re-close. If it is stuck in #closing, the controller recovers it with reconcileSession (EVM: confirm-only re-poll of the parked tx; ICP: reads the escrow balance). forceResolveSession is a last resort: it moves no funds.");
      };

      // Dispatch: EVM sessions use tECDSA-signed ERC-20 transfers. 2.21.1: inline (`await*`), so
      // the guard above and closeEvmSessionInternal's `#closing` write run in the SAME message.
      // As a self-call they did not: two closes queued together both passed the guard, and the
      // one that then failed before broadcast (the single-flight send lock) reopened the session
      // while the other was paying, so a further close paid the refund again from the shared pool.
      // 2.22.0: marked in evmClosesInFlight for its duration, as ICP closes are in icpClosesInFlight.
      if (isEvmNetwork(session.network)) {
        evmClosesInFlight.put(sessionId, ());
        return try { await* closeEvmSessionInternal(session) } finally { evmClosesInFlight.delete(sessionId) };
      };

      icpClosesInFlight.put(sessionId, ());
      try { await* closeIcpSession(session) } finally { icpClosesInFlight.delete(sessionId) };
    };

    // The ICP leg of closeSessionInternal, run with the session marked in icpClosesInFlight.
    func closeIcpSession(session : Types.InternalSessionState) : async* Types.PaymentResult {
      // Find the session's ledger (findSessionLedger). 2.22.0: a principal text that is no longer a
      // configured ledger is refused, not closed on tokens[0] — after a token config change that is
      // not the ledger holding this escrow. Refused before anything moves; the session is left #open
      // (as a failed fee query leaves it) for a close once the ledger is configured again.
      let tokenConfig = switch (findSessionLedger(session.token)) {
        case (?tc) { tc };
        case (null) {
          session.status := #open;
          return #settlementFailed("Session token " # session.token # " does not resolve to a configured ledger — nothing moved; the session stays open. Either that ledger was removed from the configuration (configure it again, then close), or the session was opened before 2.22.0 with an unconfigured token and its escrow is on the ledger that was then first in the configuration. Check which ledger holds the session's escrow before changing the configuration.");
        };
      };

      // H-4: Setting #closing BEFORE any async operations freezes session.consumed —
      // consumeVoucher rejects vouchers when status != #open, preventing TOCTOU on arithmetic.
      session.status := #closing;

      let ledger : Types.LedgerActor = actor (Principal.toText(tokenConfig.ledger));

      // 2.17.0: the escrow holds exactly `deposited` and icrc1_transfer takes the fee on top, so a
      // session consumed to within one fee of it can settle at most deposited − fee (settling
      // `consumed` failed on every expiry tick). The fee sizes the settle: queried first, never guessed.
      let fee : Nat = try { await ledger.icrc1_fee() } catch (e) {
        session.status := #open;
        return #settlementFailed("Fee query failed (icrc1_fee): " # Error.message(e) # " — nothing moved; the session stays open and the close can be retried");
      };
      let settleAmount = Nat.min(session.consumed, Utils.satSub(session.deposited, fee));

      // Settle consumed amount (less the fee when the remainder cannot cover it) to recipient
      var settleBlockIndex : ?Nat = null;
      if (settleAmount > 0) {
        // 2.18.1: inline (`await*`): no self-call, so one outstanding call fewer; a ledger reject still
        // throws into this catch.
        // 2.20.0: a reject the system raised before the ledger ran moved nothing: reopen for a retry,
        // as since 2.17.3. Any other reject is UNKNOWN (Utils.rejectedBeforeExecution): the ledger
        // may have committed the settle and then failed, and reopening would let the next close
        // (the expiry sweep's, unattended) settle a second time out of the payer's escrow. So the
        // session stays #closing, which nothing re-closes, until reconcileSession reads the escrow
        // balance and decides.
        let settleResult = try { await* escrowManager.settleCore(ledger, session.subaccount, recipientAccount(), settleAmount) } catch (e) {
          if (Utils.rejectedBeforeExecution(Error.code(e))) {
            #err("ledger call rejected before it ran (nothing moved): " # Error.message(e));
          } else {
            return #settlementPending("Settle leg rejected (" # debug_show (Error.code(e)) # "): the outcome is UNKNOWN — the recipient may have been paid. The session stays #closing. Once the ledger is reachable, the canister's controller runs reconcileSession(\"" # session.id # "\"): it reads the escrow balance and either reopens the session (nothing was paid) or closes it with the remainder recoverable by the payer. Do not pay again meanwhile. " # Error.message(e));
          };
        };
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
      //   deposited - settleAmount - settleFee (if settleAmount > 0)
      // The refund transfer itself costs another fee.
      // So the max refundable amount is: escrowBalance - refundFee

      // Guard: consumed must never exceed deposited
      if (session.consumed > session.deposited) {
        session.status := #closed;
        return #settlementFailed("Invariant violation: consumed > deposited");
      };

      let settleFees = if (settleAmount > 0) { fee } else { 0 };
      let escrowBalance = Utils.satSub(session.deposited, settleAmount + settleFees);
      var refundBlockIndex : ?Nat = null;
      let refunded = Utils.satSub(escrowBalance, fee);
      if (refunded > 0) {
        // 2.17.4: a ledger reject on the refund is handled like a refund the ledger refused, rather
        // than leave the session resting in #closing, which recoverEscrow refuses. 2.20.0: unlike
        // the settle leg, this is safe even when the reject's outcome is unknown. If the refund did
        // land, the owed figure recorded below overstates what is left, but recoverEscrow pays only
        // from this session's own escrow subaccount, which that refund emptied: nothing is paid twice.
        var refundRejected = false;
        let refundResult = try {
          await* escrowManager.refundCore(ledger, session.subaccount, { owner = session.payer; subaccount = null }, refunded);
        } catch (e) {
          refundRejected := true;
          #err(Error.message(e));
        };
        switch (refundResult) {
          case (#err(msg)) {
            // The refund failed — mark closed anyway, releasing the daily reservation like any
            // terminal close. (The status guard is defensive: since 2.22.0 forceResolveSession refuses
            // a close in flight, so nothing else moves the session during these awaits.)
            // G1: the remainder is still in escrow, so measure GC retention from now.
            if (session.status == #closing) {
              session.status := #closed;
              if (session.deposited > session.consumed) {
                policy.releaseDaily(session.payer, session.spendDay, session.deposited - session.consumed);
              };
              // 2.18.0: record the owed remainder (the computed escrow balance, never a ledger query) so
              // it is reported and its record outlives the 24h GC until the payer recovers it; since
              // 2.22.0 it is also what recoverEscrow pays against.
              refundOwed.put(session.id, { escrow = escrowBalance; fee });
            };
            session.lastActivityAt := Time.now();
            let leg = if (refundRejected) { "Refund leg rejected" } else { "Refund leg failed" };
            return #settlementFailed(leg # " (session marked #closed): " # msg # " — the remainder stays in the session's escrow subaccount and is recoverable by the payer via recoverEscrow(sessionId).");
          };
          case (#ok(blockIdx)) { refundBlockIndex := ?blockIdx };
        };
      };

      // 2.17.2 (S-3 for ICP): a successful close is TERMINAL. The expiry sweep sets #expired before
      // calling in, and ending in #expired again let a later re-close through the guard above; its
      // settle then failed on the drained escrow and reverted the session to #open, where the sweep
      // retried it forever. End in #closed so any re-close is refused.
      // 2.17.3: guarded so a forceResolveSession during the awaits could not make it release the
      // daily reservation twice; since 2.22.0 the force refuses a close in flight, so it is defensive.
      if (session.status == #closing) {
        session.status := #closed;
        // M-9 (v2): Credit the unused deposit back against the daily limit (the full
        // deposit was reserved at open; only `consumed` should count as spend).
        if (session.deposited > session.consumed) {
          policy.releaseDaily(session.payer, session.spendDay, session.deposited - session.consumed);
        };
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
        amount = settleAmount; // what reached the recipient (consumed unless the fee ate into it)
        token = session.token;
        sender = Principal.toText(session.payer);
        // Stamp the account funds actually SETTLED into — recipientAccount(), in ICRC-1
        // textual form — not the consumer-supplied intent.recipient display text. On this
        // (ICP) rail the settle above is directed by config, so a subaccounted config with a
        // bare-principal intent text would otherwise produce a receipt naming an account the
        // funds never touched (the 2.12.0 defect class, one rail over). The EVM close receipt
        // (closeEvmSessionInternal) keeps session.recipient: there the text IS the transfer
        // target the canister signed for.
        recipient = Utils.icrc1AccountText(config.recipient.owner, config.recipient.subaccount);
        network = session.network;
        timestamp = Time.now();
        txHash = closeTxHash;
        sessionId = ?session.id;
        refunded = ?refunded;
      });
    };

    // ── Expiry timer (self-arming) ──
    //
    // A recurring timer is billed per TICK — the message-execution base fee — not per unit of
    // work done, so guarding inside the callback saves nothing and an always-on 60s sweep is a
    // fixed cost for the canister's entire life (measured by a consumer running one canister per
    // user: ~23.6M cycles/tick, i.e. ~1.4B cycles/hour for this timer alone, on a canister that
    // never opened a session). So the sweep is armed only while there is session state to act on.
    //
    // CONTRACT: arm on every path that CREATES session state; the callback disarms itself once no
    // session state remains. The asymmetry is deliberate — a missed ARM site silently stops expiry
    // (deposits stay escrowed past their deadline), a missed DISARM only wastes cycles — so arm
    // aggressively and let the callback decide when to stop. Both session-creating paths live in
    // this module (openSession's ICP insert and openEvmSession's), and startTimers arms
    // unconditionally, so a consumer never has to reason about this.
    //
    // ADDING A THIRD SESSION-CREATING PATH? It must call armExpiryTimer<system>() right after its
    // `sessions.put`. No unit test can catch a miss — `mops test` has no timer system API, so
    // nothing here can arm or observe a real timer — so the guard is a SOURCE gate:
    // scripts/check-expiry-arm-sites.sh (CI job `verify-scripts`, with a --self-test). It requires
    // every `sessions.put` in this file to either arm the sweep or be listed there as covered
    // some other way (loadStable is, via startTimers' unconditional arm).
    var expiryTimer : ?Timer.TimerId = null;
    var expiryIntervalSeconds : Nat = 60;
    // Cadence to fall back to when there is no work, instead of disarming outright. 0 = disarm
    // (the default here: this module owns its arm sites, so nothing can create work behind the
    // timer's back). ServiceRegistry defaults this to an hourly poll because its job-creating
    // entry point is synchronous and therefore cannot arm a timer — see its own note.
    var expiryIdlePollSeconds : Nat = 0;
    var expiryFastMode : Bool = false;

    /// Whether the expiry sweep is currently armed. Read it to confirm an idle canister really
    /// has stopped ticking (and, on a busy one, that expiry is actually scheduled).
    public func expiryTimerArmed() : Bool { expiryTimer != null };

    /// Whether the expiry sweep has anything to act on: any session not yet `#closed`. `#open`
    /// sessions expire. `#closing` and `#expired` ones are counted too, though the sweep cannot
    /// advance them: a failed close returns them to `#open` (a settle that fails, a payer's close
    /// of an `#expired` session), and a session reopened outside a tick, after the timer had
    /// stopped, would never expire. Only `#closed` is final. 2.17.5: a `#closed` record no longer
    /// keeps the sweep ticking through its 24h retention; it is deleted by the first sweep after
    /// that, so retention is at least 24h (the next session opened, or an upgrade, arms one).
    public func hasExpiryWork() : Bool {
      for ((_, s) in sessions.entries()) { if (s.status != #closed) return true };
      false;
    };

    func cancelExpiryTimer() {
      switch (expiryTimer) {
        case (?id) { Timer.cancelTimer(id); expiryTimer := null };
        case (null) {};
      };
    };

    // Arm (or re-arm) the sweep at `seconds`. `fast` records which cadence is running so a tick
    // can tell "idle poll that just found work" from "already sweeping".
    func armExpiryAt<system>(seconds : Nat, fast : Bool) {
      cancelExpiryTimer();
      expiryFastMode := fast;
      expiryTimer := ?Timer.recurringTimer<system>(
        #seconds seconds,
        func() : async () {
          // `await*`, not `await closeExpiredSessions()`: a call to a local `async` function is a
          // message the canister sends itself, and every message pays the base fee (2.17.5).
          let _results = await* sweepExpiredSessions();
          // H-1: Remove #closed sessions older than 24h to prevent unbounded map growth
          gcClosedSessions();
          // ── ATOMIC TAIL — do NOT introduce an `await` below this line. ──
          // Motoko commits state at each await, so a session opened by another message DURING the
          // awaits above is already visible to hasExpiryWork() here (we won't disarm on it), and a
          // session opened after the cancel below sees expiryTimer == null and re-arms. An await
          // between the check and the cancel would reopen exactly the window where an #open
          // session is left with no timer to expire it.
          switch (Utils.expiryCadence(hasExpiryWork(), expiryFastMode, expiryIdlePollSeconds)) {
            case (#stay) {};
            case (#switchToFast) { armExpiryAt<system>(expiryIntervalSeconds, true) };
            case (#switchToIdle) { armExpiryAt<system>(expiryIdlePollSeconds, false) };
            case (#disarm) { cancelExpiryTimer() };
          };
        },
      );
    };

    /// Arm the expiry sweep at its working cadence if it is not already running there
    /// (idempotent). Called automatically by every session-creating path and by
    /// Gateway.startTimers; call it directly only if you drive this Sessions instance yourself
    /// (e.g. after loadStable on upgrade). Arming is UNCONDITIONAL by design: on upgrade a
    /// `persistent actor` re-runs its init body — where startTimers lives — BEFORE postupgrade
    /// restores stable sessions, so a predicate-gated arm would leave exactly the canisters that
    /// DO have live sessions with no timer. The first tick disarms if there is nothing to do.
    public func armExpiryTimer<system>() {
      if (expiryTimer != null and expiryFastMode) return;
      armExpiryAt<system>(expiryIntervalSeconds, true);
    };

    /// Set the sweep cadence in seconds (default 60), applied immediately if armed. Expiry
    /// latency is bounded by this interval: a session is closed within `seconds` of passing its
    /// maxDuration/idleTimeout, and until then it holds its slice of maxConcurrentSessions and of
    /// the EVM pool cap. Nothing about settlement correctness depends on the cadence (a close
    /// settles from the canister's own escrow with its own signature — there is no external
    /// deadline to miss), so raising it trades expiry latency and held capacity for cycles.
    public func setExpiryIntervalSeconds<system>(seconds : Nat) : { #ok; #err : Text } {
      if (seconds == 0) { return #err("expiry interval must be at least 1 second") };
      expiryIntervalSeconds := seconds;
      if (expiryTimer != null and expiryFastMode) { armExpiryAt<system>(seconds, true) };
      #ok;
    };

    /// Cadence to poll at when there is nothing to expire; 0 (the default) disarms instead.
    /// Leave it at 0 unless you create sessions through a path outside this module.
    public func setExpiryIdlePollSeconds<system>(seconds : Nat) : { #ok; #err : Text } {
      expiryIdlePollSeconds := seconds;
      if (expiryTimer != null and not expiryFastMode) {
        if (seconds == 0) { cancelExpiryTimer() } else { armExpiryAt<system>(seconds, false) };
      };
      #ok;
    };

    /// Close all expired or idle sessions.
    public func closeExpiredSessions() : async [Types.PaymentResult] { await* sweepExpiredSessions() };

    // The sweep's body, run inline by the timer (no self-call). Each session's close is still a
    // separate message (`await closeSessionInternal`), so a trap in one close fails only that close.
    func sweepExpiredSessions() : async* [Types.PaymentResult] {
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
      for ((sessionId, _) in buf.values()) {
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
              // 2.17.3: the close is a separate message. If it is rejected or traps before it commits
              // #closing, nothing moved: revert #expired to #open so the next tick retries, instead of
              // leaving the escrow in a status the sweep skips and the 24h GC deletes.
              resultBuf[i] := try { await closeSessionInternal(sessionId) } catch (e) {
                switch (sessions.get(sessionId)) {
                  case (?s) {
                    if (s.status == #expired) {
                      s.status := #open;
                      #settlementFailed("Expiry close not delivered — session left open for retry: " # Error.message(e));
                    } else {
                      #settlementFailed("Expiry close failed mid-close (session " # debug_show (s.status) # "; a #closing one needs the controller's reconcileSession): " # Error.message(e));
                    };
                  };
                  case (null) { #settlementFailed("Expiry close failed: " # Error.message(e)) };
                };
              };
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

    /// Observability (NEW-4): counts of sessions by status. `closing` is the parked count — an EVM
    /// close that broadcast a settle/refund but hasn't confirmed, an ICP close whose settle was
    /// rejected with an unknown outcome (2.20.0), or an ICP open whose deposit was (2.21.0); a
    /// non-zero, non-decreasing `closing` means a deposit is parked and needs reconcileSession.
    /// `refundOwed` (2.18.0): closed ICP sessions that left payer funds in escrow (a failed refund leg;
    /// since 2.20.0 a reconcileSession, since 2.22.0 a forceResolveSession) and that the payer has not
    /// yet emptied with recoverEscrow — counted in `closed` too. A non-zero, non-decreasing value is a
    /// payer to contact; the records behind it are refundOwedToStable(). One whose escrow is in fact
    /// empty (the "failed" refund landed) never clears by itself: clearRefundOwed.
    public func sessionCounts() : {
      total : Nat; open : Nat; closing : Nat; closed : Nat; expired : Nat; refundOwed : Nat;
    } {
      var total = 0; var nOpen = 0; var nClosing = 0; var nClosed = 0; var nExpired = 0;
      var nOwed = 0;
      for (id in refundOwed.keys()) { switch (sessions.get(id)) { case (?_) { nOwed += 1 }; case (null) {} } };
      for ((_, s) in sessions.entries()) {
        total += 1;
        switch (s.status) {
          case (#open) { nOpen += 1 };
          case (#closing) { nClosing += 1 };
          case (#closed) { nClosed += 1 };
          case (#expired) { nExpired += 1 };
        };
      };
      { total; open = nOpen; closing = nClosing; closed = nClosed; expired = nExpired; refundOwed = nOwed };
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
      s.lastActivityAt := Time.now(); // G1: funds may still be owed — a full GC window to recover them
      closeParkedTxs.delete(s.id);
      if (s.deposited > s.consumed) { policy.releaseDaily(s.payer, s.spendDay, s.deposited - s.consumed) };
    };

    /// Operator escape hatch for a session STUCK in #closing, when reconcileSession cannot resolve it
    /// (an EVM close with no parked tx, or a ledger that stays unreachable). Moves NO funds; the
    /// operator reconciles the funds out-of-band. Releases the session's canister-side reservations
    /// and forces it to #closed so GC can reclaim it. The consumer MUST gate this on
    /// Principal.isController.
    /// 2.22.0: refused while a close of the session is in flight (ICP or EVM), as reconcileSession
    /// is; call again once it returns. Forcing a live close let a close that then failed reopen the
    /// finalized session.
    /// 2.20.0, ICP: try reconcileSession first. 2.22.0: forcing an ICP session records what its close
    /// would leave the payer as owed (Types.RefundOwed): deposited − consumed, with `fee` 0 because
    /// this call cannot ask the ledger. recoverEscrow then pays the payer at most that in total, each
    /// recovery also paying the ledger's current fee out of it. If the settle never landed, the
    /// recipient's `consumed` share stays in the escrow subaccount: no library call moves it.
    public func forceResolveSession(sessionId : Text) : { #ok; #err : Text } {
      switch (sessions.get(sessionId)) {
        case (null) { #err("Session not found") };
        case (?s) {
          if (s.status != #closing) {
            return #err("Session is not stuck in #closing (status: " # debug_show (s.status) # ")");
          };
          if (icpClosesInFlight.get(sessionId) != null or evmClosesInFlight.get(sessionId) != null) {
            return #err("A close of this session is still in flight — call again once it returns");
          };
          finalizeClosedSession(s);
          // The remainder as closeIcpSession computes it (deposited − settled − settle fee, settled =
          // consumed) with the fee unknown: never a balance query (anyone can pay into an escrow).
          if (not isEvmNetwork(s.network) and s.deposited > s.consumed) {
            refundOwed.put(sessionId, { escrow = s.deposited - s.consumed; fee = 0 });
          };
          #ok;
        };
      };
    };

    /// v2.1.1 recovery (controller-only via the consumer): CONFIRM-ONLY finalize an EVM session
    /// parked in #closing. Re-polls the stored parked close tx and applies sessionReconcileDecision
    /// — NEVER broadcasts. A confirmed refund (or a confirmed settle with no remainder) → #closed;
    /// a confirmed settle WITH a remainder still owed can't be auto-completed confirm-only (the
    /// refund is unsent) → forceResolveSession + sweepEvm. #pending/#reverted/#err → stay parked.
    /// A leg parked because its send call was rejected has no hash to poll: the answer says it may
    /// have been broadcast, for the operator to check on chain before forcing.
    ///
    /// 2.20.0, ICP: a session left #closing because its settle was rejected with an unknown outcome
    /// (closeSessionInternal returned #settlementPending). Reads the session's escrow subaccount
    /// balance and decides; moves no funds itself:
    ///   - balance >= deposited: the settle did not land. Reopens the session (#open) so a normal
    ///     close (or the expiry sweep) settles it once.
    ///   - balance < deposited: the settle landed. Ends #closed, releases the daily reservation, and
    ///     records the remaining escrow as owed to the payer, recoverable with recoverEscrow.
    /// 2.21.0, ICP: also a session parked at open because its deposit was rejected with an unknown
    /// outcome (nothing consumed). The full deposit in escrow opens it; less closes it and records
    /// nothing as owed (no settle was ever sent). Its openedAt is the open attempt's, so a late
    /// reconcile can open a session already past maxDuration, which the next sweep closes and
    /// refunds less the fee.
    /// Sound because the subaccount is this session's alone and only this canister moves funds out
    /// of it: a transfer in can only raise the balance, and if that makes a landed settle read as
    /// "did not land", the second settle is paid out of the transfer, not the payer's share.
    /// Refused while a close of the session is in flight (2.22.0: EVM too). A failed balance or fee
    /// query leaves the session #closing; call again once the ledger is reachable. 2.22.0: so does a
    /// session token naming a ledger that is no longer configured (Utils.findSessionLedger).
    public func reconcileSession(sessionId : Text) : async { #ok : Text; #err : Text } {
      let session = switch (sessions.get(sessionId)) { case (null) { return #err("Session not found") }; case (?s) { s } };
      if (session.status != #closing) return #err("Session is not parked in #closing (status: " # debug_show (session.status) # ")");
      if (not isEvmNetwork(session.network)) return await* reconcileIcpClose(session);
      if (evmClosesInFlight.get(sessionId) != null) return #err("A close of this session is still in flight — call again once it returns");
      let parked = switch (closeParkedTxs.get(sessionId)) { case (null) { return #err("Session is #closing but has no parked tx — use forceResolveSession") }; case (?p) { p } };
      if (parked.txHash == HASH_UNKNOWN) {
        let (name, owed) = switch (parked.leg) {
          case (#Settle) { ("settle", "the consumed amount to the recipient and the remainder to the payer") };
          case (#Refund) { ("refund", "the remainder to the payer") };
        };
        return #err("Session is #closing with its " # name # " leg parked, but that leg's send was rejected and no tx hash came back: it may have been broadcast. Check the canister's EVM address on a block explorer for that transfer before forcing, then forceResolveSession and sweepEvm only what did not land of: " # owed);
      };
      let deposit = switch (session.evmDeposit) { case (null) { return #err("Session has no EVM deposit data") }; case (?d) { d } };
      let sender = switch (evmSenderSource()) { case (null) { return #err("EVM sender not configured") }; case (?s) { s } };
      // 2.22.0 (F1): reconcileTransaction also reports a parked tx that appears not to have landed (#dropped).
      let outcome = await sender.reconcileTransaction(deposit.chainId, parked.txHash, 1);
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

    // reconcileSession's ICP branch (2.20.0); see its doc comment.
    func reconcileIcpClose(session : Types.InternalSessionState) : async* { #ok : Text; #err : Text } {
      let id = session.id;
      if (icpClosesInFlight.get(id) != null) return #err("A close of this session is still in flight — call again once it returns");
      // 2.22.0: the session's own ledger (findSessionLedger) or nothing. A fallback to tokens[0] for a
      // ledger no longer configured read another ledger's balance (0) and closed the session as
      // "settle landed".
      let tokenConfig = switch (findSessionLedger(session.token)) {
        case (?tc) { tc };
        case (null) { return #err("Session token " # session.token # " does not resolve to a configured ledger; the session stays #closing. Either that ledger was removed from the configuration (configure it again, then call again), or the session was opened before 2.22.0 with an unconfigured token and its escrow is on the ledger that was then first in the configuration. Check which ledger holds the session's escrow before changing the configuration.") };
      };
      let ledger : actor {
        icrc1_balance_of : (Types.Account) -> async Nat;
        icrc1_fee : () -> async Nat;
      } = actor (Principal.toText(tokenConfig.ledger));
      let fee = try { await ledger.icrc1_fee() } catch (e) {
        return #err("Fee query failed (" # Error.message(e) # "); the session stays #closing — call again once the ledger is reachable");
      };
      let balance = try {
        await ledger.icrc1_balance_of({ owner = canisterPrincipal; subaccount = ?session.subaccount });
      } catch (e) {
        return #err("Escrow balance query failed (" # Error.message(e) # "); the session stays #closing — call again once the ledger is reachable");
      };
      // Re-fetch after the awaits: a forceResolveSession or another reconcile may have moved it.
      let s2 = switch (sessions.get(id)) { case (null) { return #err("Session vanished during reconcile") }; case (?s) { s } };
      if (s2.status != #closing or icpClosesInFlight.get(id) != null) {
        return #err("Session changed during reconcile (status: " # debug_show (s2.status) # ") — nothing done");
      };
      if (balance >= s2.deposited) {
        s2.status := #open;
        s2.lastActivityAt := Time.now();
        if (s2.consumed == 0) {
          // 2.21.0: a deposit parked by an unknown reject at open (nothing consumed, no settle sent).
          return #ok("Escrow holds the full deposit (" # Nat.toText(balance) # " >= " # Nat.toText(s2.deposited) # "): the deposit landed. Session opened.");
        };
        #ok("Escrow still holds the full deposit (" # Nat.toText(balance) # " >= " # Nat.toText(s2.deposited) # "): the settle did not land. Session reopened — close it again (or let the expiry sweep).");
      } else {
        finalizeClosedSession(s2); // #closed + releaseDaily (shared with forceResolveSession)
        // 2.21.0: a close sends a settle only when something was consumed, so with nothing consumed
        // the escrow is short because the deposit never arrived (a deposit parked at open), or
        // because a refund already left. Nothing is owed either way; recording the escrow as owed
        // would point recoverEscrow at funds that are not there.
        if (s2.consumed == 0) {
          return #ok("The escrow holds " # Nat.toText(balance) # " of " # Nat.toText(s2.deposited) # " and nothing was consumed: the deposit did not land (or its refund already did). Session #closed; nothing is owed.");
        };
        // The owed remainder is computed as the close computes it, not taken from `balance`: anyone
        // can transfer into an escrow subaccount (Types.RefundOwed). The query only decided above
        // whether the settle landed.
        let settled = Nat.min(s2.consumed, Utils.satSub(s2.deposited, fee));
        let left = Utils.satSub(s2.deposited, settled + fee);
        if (left > fee) { refundOwed.put(id, { escrow = left; fee }) };
        #ok("The settle landed (escrow holds " # Nat.toText(balance) # " of " # Nat.toText(s2.deposited) # "). Session #closed; the payer can recover the remainder with recoverEscrow.");
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
    /// address; on a mined revert it drops the entry only while the deposit's authorization reads
    /// unused (another tx may have executed it, and the deposit arrived); otherwise leaves it for a
    /// later retry. The entry is claimed synchronously before the first await so two concurrent
    /// reconciles of the same tx can't double-refund. A rejected receipt or authorization read puts
    /// it back; a rejected refund send, or a refund signed but refused for gas, does not (the refund
    /// may have gone out). Controller-gated by the consumer.
    public func reconcileEvmDeposit(txHash : Text) : async { #refunded : Text; #reverted; #stillPending; #notFound; #err : Text } {
      let dep = switch (pendingEvmDeposits.get(txHash)) { case (?d) { d }; case (null) { return #notFound } };
      let sender = switch (evmSenderSource()) { case (?s) { s }; case (null) { return #err("EVM sender not configured") } };
      // Claim synchronously (no await between get and delete) so a concurrent reconcile of the same
      // tx sees #notFound and cannot double-refund. Restore on any non-terminal outcome, a rejected
      // read included (an uncaught reject would keep the delete and lose the entry).
      pendingEvmDeposits.delete(txHash);
      // The deposit authorization's state; a rejected call reads as unknown.
      func authState() : async* EvmSender.AuthorizationState {
        try { await sender.authorizationState(dep.chainId, dep.token, EvmUtils.hexToBytes(dep.payerEvmAddress), Blob.toArray(dep.authNonce)) } catch (e) {
          #unknown("authorizationState call rejected: " # Error.message(e));
        };
      };
      let receipt = try { await sender.reconcileTransaction(dep.chainId, txHash, 4) } catch (e) {
        pendingEvmDeposits.put(txHash, dep);
        return #err("receipt poll rejected: " # Error.message(e) # " — the entry is kept; retry reconcile");
      };
      switch (receipt) {
        case (#confirmed) {
          // Deposit mined into the shared pool — refund it to the payer's EVM address. A rejected
          // send may have broadcast the refund, so the entry is not restored (a retry could refund
          // twice); the answer and the canister log say so.
          let refund = try {
            await sender.sendErc20TransferConfirmed(dep.chainId, dep.token, dep.payerEvmAddress, dep.amount, 4);
          } catch (e) {
            let msg = "refund send was rejected (" # Error.message(e) # ") and may have been broadcast; no tx hash came back. The entry for deposit " # txHash # " is not restored, so a retry cannot refund twice. Check the canister's EVM address on chain for a transfer of " # Nat.toText(dep.amount) # " to " # dep.payerEvmAddress # "; only if none landed, return it with sweepEvm";
            Debug.print("ic402 reconcileEvmDeposit: " # msg);
            return #err(msg);
          };
          switch (refund) {
            case (#confirmed(h)) { #refunded(h) }; // stays deleted — done
            case (#reverted(h)) { pendingEvmDeposits.put(txHash, dep); #err("refund reverted on-chain (tx " # h # ") — retry reconcile") };
            // Refund broadcast but unconfirmed — do NOT restore (it may land; restoring risks a
            // double refund on retry). Operator verifies the tx before any manual re-refund.
            case (#pending(h)) { #err("refund broadcast but not confirmed (tx " # h # ") — verify on-chain before retrying to avoid double refund") };
            case (#err(e)) {
              // Signed but refused for gas: a provider may have accepted it, so the refund may
              // have gone out. Not restored, as for a rejected send; the answer and the log say so.
              switch (EvmSender.gasRefusedTxHash(e)) {
                case (?h) {
                  let msg = "refund tx " # h # " was signed, but the providers refused it for lack of gas; one may have accepted it, so the refund may have gone out. The entry for deposit " # txHash # " is not restored, so a retry cannot refund twice. Check that hash on chain; only if it never landed, return " # Nat.toText(dep.amount) # " to " # dep.payerEvmAddress # " with sweepEvm";
                  Debug.print("ic402 reconcileEvmDeposit: " # msg);
                  #err(msg);
                };
                case (null) { pendingEvmDeposits.put(txHash, dep); #err("refund failed (nothing broadcast): " # e) };
              };
            };
          };
        };
        case (#reverted) {
          // THIS tx reverting does not mean the deposit did not arrive: anyone can submit the
          // authorization, so another tx may have executed it first (as at open). Drop the entry
          // only when the token says the authorization is unused.
          switch (await* authState()) {
            case (#unused) { #reverted }; // nothing landed; stays dropped
            case (#used) {
              pendingEvmDeposits.put(txHash, dep);
              #err("deposit tx reverted, but its authorization is used on chain: another transaction executed it (the deposit may have arrived) or the payer cancelled it — verify on chain and, if the deposit arrived, return it with sweepEvm");
            };
            case (#unknown(e)) {
              pendingEvmDeposits.put(txHash, dep);
              #err("deposit tx reverted; whether its authorization was executed by another transaction could not be checked (" # e # ") — retry reconcile");
            };
          };
        };
        case (#pending) { pendingEvmDeposits.put(txHash, dep); #stillPending };
        case (#err(e)) { pendingEvmDeposits.put(txHash, dep); #err("receipt poll failed: " # e) };
        // 2.22.0 (F1): an agreed "no receipt" after another tx took this tx's nonce — it appears
        // not to have landed. Nothing arrived THROUGH it, but its authorization can still be
        // submitted by anyone until validBefore — so drop the entry (as #reverted) only when the
        // token says the authorization is unused; otherwise keep it and report.
        case (#dropped(why)) {
          switch (await* authState()) {
            case (#unused) { #reverted };
            case (#used) {
              pendingEvmDeposits.put(txHash, dep);
              #err("deposit tx appears not to have landed (" # why # "), but its authorization is used on chain: another transaction executed it or the payer cancelled it — verify on chain and, if the deposit arrived, return it with sweepEvm");
            };
            case (#unknown(e)) {
              pendingEvmDeposits.put(txHash, dep);
              #err("deposit tx appears not to have landed (" # why # "); whether its authorization was executed by another transaction could not be checked (" # e # ") — retry reconcile");
            };
          };
        };
      };
    };

    /// H-1: remove #closed sessions idle past the 24h retention period (called after
    /// closeExpiredSessions) to prevent unbounded HashMap growth. 2.22.0: #closed only. An #expired
    /// session is one whose close has not finished (the sweep marks it just before closing it, and a
    /// close that was not delivered reverts it to #open): deleting it deleted its escrow's only key.
    public func gcClosedSessions() {
      let retentionNanos = 24 * 60 * 60 * 1_000_000_000; // 24 hours
      let now = Time.now();
      let toRemove = Iter.toArray(
        Iter.filter<(Text, Types.InternalSessionState)>(
          sessions.entries(),
          func((id, s)) {
            // 2.18.0: a session still owed a refund keeps its record — deleting it would leave the
            // remainder in escrow with no way left to recover it.
            s.status == #closed and (now - s.lastActivityAt > retentionNanos)
            and refundOwed.get(id) == null;
          },
        )
      );
      for ((id, _) in toRemove.values()) {
        sessions.delete(id);
      };
    };

    // ── EVM session close ──

    // A close leg that was signed but refused for lack of gas (EvmSender.gasRefusedTxHash): two
    // providers refused it, but a third may have accepted it, so it is maybe sent. The session stays
    // #closing with the leg parked under its signed hash, for reconcileSession (confirm-only).
    func parkGasRefusedLeg(sessionId : Text, leg : { #Settle; #Refund }, hash : Text) : Types.PaymentResult {
      closeParkedTxs.put(sessionId, { leg; txHash = hash });
      let name = switch (leg) { case (#Settle) { "settle" }; case (#Refund) { "refund" } };
      #settlementPending("EVM " # name # " was signed, but the providers refused it for lack of gas (fund the canister's EVM address); one may have accepted it, so it is not sent again (session parked — reconcileSession; tx " # hash # ")");
    };

    // A close leg whose send call was rejected (the sender trapped after broadcasting, say): the
    // transfer may have gone out, and no hash came back. The leg is parked with HASH_UNKNOWN, so
    // reconcileSession tells the operator to check the chain instead of answering "no parked tx".
    func parkRejectedLeg(sessionId : Text, leg : { #Settle; #Refund }, why : Text) : Types.PaymentResult {
      closeParkedTxs.put(sessionId, { leg; txHash = HASH_UNKNOWN });
      let name = switch (leg) { case (#Settle) { "settle" }; case (#Refund) { "refund" } };
      #settlementPending("EVM " # name # " send was rejected (" # why # "); it may have been broadcast, and no tx hash came back. Session parked — check the chain before any recovery (reconcileSession explains)");
    };

    /// Close an EVM session: settle consumed to recipient, refund remainder to payer.
    /// Both operations use tECDSA-signed ERC-20 transfer transactions.
    func closeEvmSessionInternal(session : Types.InternalSessionState) : async* Types.PaymentResult {
      let wasExpired = (session.status == #expired);
      session.status := #closing;

      let deposit = switch (session.evmDeposit) {
        case (?d) { d };
        case (null) {
          session.status := if (wasExpired) { #expired } else { #closed };
          return #settlementFailed("Session has no EVM deposit data");
        };
      };

      let sender = switch (evmSenderSource()) {
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
      // 2.22.0 (E10): no settle leg when the recipient IS the canister's own EVM address — the
      // consumed share already sits there, so the leg was a self-transfer that paid gas and gave
      // the close one more step that could park it.
      let settlesToSelf = switch (evmRecipientAddress.get()) {
        case (?self) { EvmUtils.addressesEqual(self, session.recipient) };
        case (null) { false };
      };
      if (session.consumed > 0 and not settlesToSelf) {
        // A rejected send call is not "nothing sent": the sender may have broadcast before it.
        let settled = try {
          await sender.sendErc20TransferConfirmed(
            deposit.chainId, deposit.tokenAddress, session.recipient, session.consumed, 4,
          );
        } catch (e) { return parkRejectedLeg(session.id, #Settle, Error.message(e)) };
        switch (settled) {
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
            // Signed but refused for gas: a provider may have accepted it. Park it with its hash for
            // reconcileSession, whoever asked for the close; never reopen (a later close re-sends).
            switch (EvmSender.gasRefusedTxHash(msg)) {
              case (?hash) { return parkGasRefusedLeg(session.id, #Settle, hash) };
              case (null) {};
            };
            // M10: pre-broadcast #err means NOTHING was broadcast for this session (safe to roll
            // back — no funds moved, consumed unsettled). For a CLIENT-initiated close, restore
            // #open so the session stays usable and the client can retry; otherwise a transient
            // reject (e.g. a concurrent tx holding the EvmSender single-flight lock — the M10
            // race) would strand it permanently in #closing with no retry path. For a
            // timer-initiated (expired) close, keep #closing to avoid the 60s expiry timer
            // re-driving a persistent failure every tick (S16/C1). 2.22.0: except the busy send
            // lock, which clears by itself — reopened, the next tick retries (reopenAfterUnsentLeg);
            // 2.23.2: and a gas stop's refusal (nothing signed), retried until the stop ends.
            if (reopenAfterUnsentLeg(wasExpired, true, msg)) {
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
        let refundResult = try {
          await sender.sendErc20TransferConfirmed(
            deposit.chainId, deposit.tokenAddress, deposit.payerEvmAddress, refunded, 4,
          );
        } catch (e) { return parkRejectedLeg(session.id, #Refund, Error.message(e)) };
        switch (refundResult) {
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
            // Signed but refused for gas: parked with its hash, as on the settle leg.
            switch (EvmSender.gasRefusedTxHash(msg)) {
              case (?hash) { return parkGasRefusedLeg(session.id, #Refund, hash) };
              case (null) {};
            };
            // M10: refund failed pre-broadcast (nothing broadcast). If settle ran and confirmed
            // (settleTxHash set), we must NOT reopen — a retry would re-settle consumed; park in
            // #closing. If settle was SKIPPED (consumed == 0, nothing moved at all), a
            // client-initiated close can safely reopen to #open and retry (a timer close too, when
            // the failure clears without it: reopenAfterUnsentLeg).
            if (reopenAfterUnsentLeg(wasExpired, settleTxHash == null, msg)) {
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
      // (ICP closes end in #closed too since 2.17.2: their failed second settle reopened them.)
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
    /// and only allows recovery for sessions in #closed status (2.17.3: a recovery landing during a
    /// close in progress drained the escrow under its settle, which failed and reopened the session).
    /// 2.22.0: pays only against the session's refundOwed entry (sessionCounts().refundOwed): no entry,
    /// nothing to recover. Each recovery is capped at the entry less the ledger's current fee and
    /// reduces the entry by the amount plus that fee, so the payer's total never exceeds what the close
    /// (or reconcileSession / forceResolveSession) left the payer — before, the cap was per call
    /// and a forced session's escrow could be drained of the recipient's share by repeated calls. One
    /// recovery per session at a time. The ledger is the session's own (resolved from its token);
    /// `ledger` is kept for compatibility and must be that ledger, or the call is refused.
    public func recoverEscrow(
      caller : Principal,
      ledger : Types.LedgerActor,
      sessionId : Text,
      amount : Nat,
    ) : async { #ok : Nat; #err : Text } {
      switch (await* recoverEscrowCore(caller, ledger, sessionId, amount)) {
        case (#ok(r)) { #ok(r.blockIndex) };
        case (#err(e)) { #err(e) };
      };
    };

    /// 2.23.0: recoverEscrow, reporting what moved (Types.RecoveryReceipt) instead of only the
    /// block index, so a consumer need not recompute the caps. Same checks, caps and accounting:
    /// both run recoverEscrowCore.
    public func recoverEscrowReceipt(
      caller : Principal,
      ledger : Types.LedgerActor,
      sessionId : Text,
      amount : Nat,
    ) : async { #ok : Types.RecoveryReceipt; #err : Text } {
      await* recoverEscrowCore(caller, ledger, sessionId, amount);
    };

    func recoverEscrowCore(
      caller : Principal,
      ledger : Types.LedgerActor,
      sessionId : Text,
      amount : Nat,
    ) : async* { #ok : Types.RecoveryReceipt; #err : Text } {
      // Check authorization — only session payer can recover
      switch (sessions.get(sessionId)) {
        case (?session) {
          if (not Principal.equal(caller, session.payer)) {
            return #err("Not authorized: only session payer can recover escrow");
          };
          // H-5: Only allow recovery once the close has finished
          switch (session.status) {
            case (#closed) {};
            case (#open) {
              return #err("Cannot recover escrow from an open session — close it first");
            };
            case (#closing or #expired) {
              return #err("Cannot recover escrow while a close is in progress (" # debug_show (session.status) # ") — close an #expired session with closeSession; a session resting in #closing needs the controller's reconcileSession first (it reads the escrow and reopens or closes the session)");
            };
          };
          if (refundOwed.get(sessionId) == null) {
            return #err("Nothing is owed on this session: its close left no remainder in escrow, or it has been recovered already (EVM sessions are never recoverable here). If the canister was upgraded without persisting its owed refunds (refundOwedToStable), the entry was lost: the controller restores it with loadRefundOwed.");
          };
          // 2.22.0: the session's own ledger (findSessionLedger), never a caller-chosen canister.
          let tokenConfig = switch (findSessionLedger(session.token)) {
            case (?tc) { tc };
            case (null) {
              return #err("Session token " # session.token # " does not resolve to a configured ledger. Either that ledger was removed from the configuration (configure it again, then retry), or the session was opened before 2.22.0 with an unconfigured token and its escrow is on the ledger that was then first in the configuration. Check which ledger holds the session's escrow before changing the configuration.");
            };
          };
          if (not Principal.equal(Principal.fromActor(ledger), tokenConfig.ledger)) {
            return #err("Wrong ledger: this session's escrow is on " # Principal.toText(tokenConfig.ledger) # ", not " # Principal.toText(Principal.fromActor(ledger)));
          };
          if (recoveriesInFlight.get(sessionId) != null) {
            return #err("A recovery of this session is already in flight — call again once it returns");
          };
          recoveriesInFlight.put(sessionId, ());
          try { await* recoverOwed(session, tokenConfig.ledger, amount) } finally { recoveriesInFlight.delete(sessionId) };
        };
        case (null) {
          return #err("Session not found: cannot authorize escrow recovery without session record");
        };
      };
    };

    // recoverEscrow's transfer, run with the session marked in recoveriesInFlight.
    func recoverOwed(session : Types.InternalSessionState, ledgerP : Principal, amount : Nat) : async* { #ok : Types.RecoveryReceipt; #err : Text } {
      let ledger : Types.LedgerActor = actor (Principal.toText(ledgerP));
      // The fee this recovery pays, out of the payer's remainder. The entry's own `fee` is the close's
      // (0 for a forced session, which could not ask the ledger), so the current one is used.
      let fee = try { await ledger.icrc1_fee() } catch (e) {
        return #err("Fee query failed (icrc1_fee): " # Error.message(e) # " — nothing moved; retry once the ledger is reachable");
      };
      let owed = switch (refundOwed.get(session.id)) {
        case (?o) { o };
        case (null) { return #err("Nothing is owed on this session any more (the entry was cleared)") };
      };
      // 2.22.0: an entry of one fee or less can never move anything (a forced session's, written
      // without the fee, or one the fee rose past). Clear it, so it stops being reported and stops
      // keeping the record from the GC.
      if (owed.escrow <= fee) {
        refundOwed.delete(session.id);
        return #err("Nothing left to recover: the owed remainder (" # Nat.toText(owed.escrow) # ") does not exceed the ledger fee (" # Nat.toText(fee) # "); the entry is cleared.");
      };
      // H-5: Cap recovery amount to unconsumed portion, and (2.22.0) to what the entry still owes
      let maxRecoverable = Nat.min(Utils.satSub(session.deposited, session.consumed), Utils.satSub(owed.escrow, fee));
      let cappedAmount = if (amount > maxRecoverable) { maxRecoverable } else { amount };
      if (cappedAmount == 0) {
        return #err("No recoverable funds: deposit fully consumed");
      };
      // H-5: Always refund to the payer's own account (no arbitrary recipient)
      let payerAccount : Types.Account = { owner = session.payer; subaccount = null };
      let subaccount = escrowManager.deriveSubaccount(session.id);
      let result = await* escrowManager.refundCore(ledger, subaccount, payerAccount, cappedAmount);
      // 2.18.0: an owed refund is settled once one fee or less is left (nothing more can move).
      switch (result) {
        case (#err(e)) { #err(e) };
        case (#ok(blockIndex)) {
          // The entry as it is now (a clearRefundOwed during the transfer leaves none).
          let owedLeft = switch (refundOwed.get(session.id)) {
            case (?o) {
              let left = Utils.satSub(o.escrow, cappedAmount + fee);
              if (left <= fee) { refundOwed.delete(session.id); 0 } else {
                refundOwed.put(session.id, { o with escrow = left });
                left;
              };
            };
            case (null) { 0 };
          };
          #ok({ blockIndex; amount = cappedAmount; fee; owedLeft });
        };
      };
    };

    /// 2.22.0: drop a session's refundOwed entry — for one whose escrow is in fact empty (the refund
    /// the close reported as failed had landed: a reject with an unknown outcome), which otherwise
    /// stays in sessionCounts().refundOwed and keeps its record from the GC for good. Check the escrow
    /// balance first: once the entry is gone recoverEscrow refuses the session, and its record is
    /// GC-eligible. Moves no funds. The consumer MUST gate this on Principal.isController.
    public func clearRefundOwed(sessionId : Text) : { #ok; #err : Text } {
      switch (refundOwed.get(sessionId)) {
        case (null) { #err("No refund is owed on session " # sessionId) };
        case (?_) { refundOwed.delete(sessionId); #ok };
      };
    };

    // ── Stable state ──

    /// 2.18.0: the owed refunds (see sessionCounts().refundOwed), for persistence across upgrades and as
    /// the list behind the count. They are deliberately not in toStable(), so no stored type changed:
    /// keep them in their own stable variable and pass them back to loadRefundOwed after loadStable.
    /// 2.22.0: persisting them is REQUIRED — recoverEscrow pays an ICP session only against its entry,
    /// so an upgrade that drops them leaves those payers' remainders in escrow with no in-band way out.
    public func refundOwedToStable() : [Types.RefundOwed] {
      Iter.toArray(
        Iter.map<(Text, { escrow : Nat; fee : Nat }), Types.RefundOwed>(
          refundOwed.entries(),
          func((sessionId, o)) { { sessionId; escrow = o.escrow; fee = o.fee } },
        )
      );
    };

    /// Restore the owed refunds saved by refundOwedToStable (replaces the current set).
    public func loadRefundOwed(data : [Types.RefundOwed]) {
      refundOwed := HashMap.HashMap<Text, { escrow : Nat; fee : Nat }>(8, Text.equal, Text.hash);
      for (r in data.values()) { refundOwed.put(r.sessionId, { escrow = r.escrow; fee = r.fee }) };
    };

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
      for (ss in data.values()) {
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
