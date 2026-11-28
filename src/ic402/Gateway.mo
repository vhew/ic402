/// ic402 — Main gateway class. Orchestrates charges, sessions, grants, and policy.
import Types "Types";
import Policy "Policy";
import Nonce "Nonce";
import Escrow "Escrow";
import GrantsMod "Grants";
import SessionsMod "Sessions";
import Time "mo:base/Time";
import Nat "mo:base/Nat";
import Nat64 "mo:base/Nat64";
import Nat8 "mo:base/Nat8";
import Int "mo:base/Int";
import Text "mo:base/Text";
import Buffer "mo:base/Buffer";
import Principal "mo:base/Principal";
import Timer "mo:base/Timer";
import Error "mo:base/Error";
import Blob "mo:base/Blob";
import Array "mo:base/Array";
import SHA256 "mo:sha2/Sha256";
import Utils "Utils";
import EvmAddress "EvmAddress";
import SchnorrSigner "SchnorrSigner";
import EvmEscrow "EvmEscrow";
import EvmRpc "EvmRpc";
import EvmSender "EvmSender";
import EvmSplits "EvmSplits";
import EvmUtils "EvmUtils";
import Eip712 "Eip712";
import Debug "mo:base/Debug";
import Cycles "mo:base/ExperimentalCycles";

module {

  /// SEC-1: pure token-bucket step (module-level → unit-testable). Refills `tokens` by the WHOLE
  /// seconds elapsed since `lastRefill` (× refillPerSec, capped at `capacity`), advancing
  /// `lastRefill` only by the credited whole seconds so fractional time carries over, then admits
  /// one token if available. Used as a GLOBAL (caller-agnostic) gate on the facilitator endpoints.
  public func tokenBucketStep(tokens : Nat, lastRefill : Int, now : Int, capacity : Nat, refillPerSec : Nat) : {
    tokens : Nat;
    lastRefill : Int;
    admit : Bool;
  } {
    let elapsedNs : Int = if (now > lastRefill) { now - lastRefill } else { 0 };
    let wholeSec : Int = elapsedNs / 1_000_000_000;
    let refilled : Nat = Nat.min(capacity, tokens + Int.abs(wholeSec) * refillPerSec);
    let newLastRefill : Int = lastRefill + wholeSec * 1_000_000_000;
    if (refilled >= 1) { { tokens = refilled - 1; lastRefill = newLastRefill; admit = true } } else {
      { tokens = refilled; lastRefill = newLastRefill; admit = false };
    };
  };

  /// Pick the token being paid on `chain`: the payer-signed `asset` when present (multi-token), else
  /// the chain's FIRST configured token (legacy / single-token). Returns "" for an empty chain.
  /// Module-level + pure so the multi-token asset selection is directly unit-testable.
  /// The PAYER chooses among the chain's tokens, and the price is compared in raw units
  /// (authorization.value == amount) — so every token listed on one chain must have the same
  /// decimals (enforced: checkEvmTokenDecimals) AND the same unit value (an operator duty: e.g.
  /// USDC beside EURC would let a payer pay the cheaper one).
  public func resolveEvmAsset(chain : Types.EvmChainConfig, asset : ?Text) : Text {
    switch (asset) {
      case (?a) { a };
      case (null) { if (chain.tokens.size() > 0) { chain.tokens[0].address } else { "" } };
    };
  };

  /// Resolve the EIP-712 domain (name/version) for the PAID token on a chain — keyed on the actual
  /// verifyingContract (`tokenAddr`), NOT tokens[0], so on a multi-token chain each token verifies
  /// against its OWN domain. Returns null when `tokenAddr` is not a configured token on the chain.
  /// Shared by verifyPayment / settle / (mirrored in) Sessions.openEvmSession.
  public func resolveEvmDomain(chain : Types.EvmChainConfig, tokenAddr : Text) : ?{ name : ?Text; version : ?Text } {
    for (tok in chain.tokens.values()) {
      if (EvmUtils.addressesEqual(tok.address, tokenAddr)) return ?{ name = tok.name; version = tok.version };
    };
    null;
  };

  /// 2.22.0 (E4, owner decision D2): refuse a chain whose tokens have different decimals. A payer
  /// picks the token (`signature.asset`), the price is compared to `authorization.value` in raw
  /// units, and a server nonce binds the chain's first token — so a chain listing a 6-decimal
  /// and an 18-decimal token let a payer pay 10^-12 of the price. The tokens on one chain must
  /// also be of equal unit value; that cannot be checked here and is the operator's duty.
  /// Used by the Gateway constructor (traps) and setEvmChains (#err).
  public func checkEvmTokenDecimals(chains : [Types.EvmChainConfig]) : { #ok; #err : Text } {
    for (chain in chains.values()) {
      if (chain.tokens.size() > 1) {
        let first = chain.tokens[0];
        for (tok in chain.tokens.values()) {
          if (tok.decimals != first.decimals) {
            return #err(
              "chain " # Nat.toText(chain.chainId) # ": token " # tok.address # " has "
              # Nat.toText(Nat8.toNat(tok.decimals)) # " decimals but " # first.address # " has "
              # Nat.toText(Nat8.toNat(first.decimals)) # " — the payer chooses the token and prices are"
              # " compared in raw units, so every token on one chain must have the same decimals"
              # " (and the same unit value)"
            );
          };
        };
      };
    };
    #ok;
  };

  /// 2.22.0 (E9): the policy principal of an EVM payer: the first 29 bytes of
  /// SHA-256("evm:" # address), where the address is the canonical lower-case 0x form of the
  /// 20 decoded bytes. Before 2.22.0 the raw `authorization.from` text was hashed, so each
  /// hex-case spelling of one address got its own daily/rate buckets and escaped a blocklist
  /// entry made from another spelling. For a lower-case 0x address the result is unchanged, so
  /// existing buckets and blocklist entries made from lower-case addresses keep working.
  /// A `from` that is not 20 bytes of hex is hashed as given (its signature cannot verify).
  public func evmPolicyPrincipal(from : Text) : Principal {
    let bytes = EvmUtils.hexToBytes(from);
    let canonical = if (bytes.size() == 20) { EvmUtils.bytesToHex(bytes) } else { from };
    let hash = Blob.toArray(SHA256.fromArray(#sha256, Blob.toArray(Text.encodeUtf8("evm:" # canonical))));
    Principal.fromBlob(Blob.fromArray(Array.subArray(hash, 0, 29)));
  };

  /// 2.22.0: who pays a charge, compared between two settles of one server nonce: the ICP
  /// `sender` text as given, or the EVM authorization's `from` as its decoded bytes (so 0x, 0X,
  /// bare hex and any letter case are one payer). Comparing the ICP text raw is safe: an attempt
  /// still in flight has passed Utils.principalFromText, which accepts only a principal's one
  /// canonical spelling, so a different text is never the same payer (and is itself refused).
  public func chargePayerKey(signature : Types.PaymentSignature) : Text {
    if (not Utils.isEvmNetwork(signature.network)) { return "icp:" # signature.sender };
    switch (signature.authorization) {
      case (?a) { "evm:" # EvmUtils.bytesToHex(EvmUtils.hexToBytes(a.from)) };
      case (null) { "evm:" };
    };
  };

  /// Entries runMaintenance removes from each map per call, at most.
  public let maintenanceCapPerMap : Nat = 10_000;

  /// Main payment gateway. Orchestrates charges, sessions, grants, escrow, and policy.
  ///
  /// Consumer obligations:
  /// - `selfPrincipal` MUST be the consuming canister's own principal (bound into voucher
  ///   payloads and escrow subaccount derivation).
  /// - Call `startTimers<system>()` once from actor context, or schedule session expiry/GC
  ///   yourself.
  /// - 2.19.0: a host that runs its own schedule can call `startTimersWith<system>({ hourlyGc =
  ///   false })` instead, which arms everything startTimers does except the hourly clean-up. It
  ///   MUST then call `runMaintenance()` at least once a day, and more often under heavy inbound
  ///   traffic. SEC-1: while `rateLimitPerMinute` is set, the rate-limit log gains an entry per
  ///   caller principal on every session-open attempt (before any other check, and principals
  ///   cost nothing to mint) and on every successful settle, so it grows with attacker-chosen
  ///   keys until a clean-up runs. The daily-spend and revoked-grant maps also grow until then.
  ///   Each runMaintenance call scans the maps whole, so a longer cadence means a bigger scan.
  /// - Persist `toStable()` in preupgrade and restore with `loadStable()` in postupgrade;
  ///   check `Ic402.checkSchemaVersion` against your persisted version BEFORE loadStable.
  /// - 2.18.0: persist `refundOwedToStable()` in its own stable variable and restore it with
  ///   `loadRefundOwed()` after loadStable (owed ICP refunds; not part of toStable()). Required
  ///   since 2.22.0: recoverEscrow pays only against these entries.
  /// - EVM rails are unavailable until the async tECDSA address derivation completes —
  ///   poll `isEvmReady()`.
  public class Gateway(config : Types.Config, selfPrincipal : Principal) {

    let policy = Policy.Engine();
    let nonceManager = Nonce.NonceManager(selfPrincipal);
    let escrowManager = Escrow.EscrowManager(selfPrincipal);
    let grants = GrantsMod.Grants(selfPrincipal);
    let evmEscrowMgr = EvmEscrow.EvmEscrowManager();
    // The hourly clean-up's timer, when startTimers armed it (2.19.0: maintenanceTimerArmed).
    var maintenanceTimer : ?Timer.TimerId = null;
    // The path every EVM key in this gateway derives under: the inbound recipient AND the
    // outbound sender. Transient by necessity — a consumer may not add a field to
    // Types.Config (its Stable*State types are structurally inlined into the consumer's own
    // stable signature), so this is re-applied after upgrade exactly like setEvmChains. It
    // defaults to [], which is what every pre-2.16.0 gateway did, so leaving it alone is
    // byte-identical to the old behaviour.
    var evmDerivationPath : [Blob] = [];
    // Whether this lifetime has committed to evmDerivationPath: setEvmDerivationPath applied it, or
    // a derive began under it. Until then the path is only the transient default, and a recipient
    // restored by loadStable does not pin it (see setEvmDerivationPath). Transient, like the path.
    var evmPathPinned : Bool = false;

    // `var`, not `let`: setEvmDerivationPath rebuilds it so the outbound sender follows the
    // recipient. Before 2.16.0 this was a `let` on the empty path, which made the same-path
    // invariant unreachable — a labelled recipient would have been funded at one address and
    // spent from another.
    var evmSenderInst : ?EvmSender.EvmSender = switch (config.ecdsaKeyName) {
      case (?keyName) { ?EvmSender.EvmSender(keyName, config.evmRpcCanister) };
      case (null) { null };
    };

    /// Move every EVM key in this gateway onto `derivationPath` — the outbound sender now,
    /// and the inbound recipient when `deriveEvmRecipient`/`…At` next derives it.
    ///
    /// Call this BEFORE the recipient is derived and before any address is published. A
    /// recipient that already exists cannot move (see `deriveEvmRecipientAt`), so changing
    /// the path afterwards would split funds from the ability to spend them — which is why
    /// this refuses once the recipient is set.
    ///
    /// NOT PERSISTED: after an upgrade the path is back at `[]`. Re-apply it on every upgrade in
    /// the init block that calls `loadStable`, AFTER `loadStable` (the order `setEvmChains`
    /// uses), and call `startTimers` (or `deriveEvmRecipient` after the re-apply):
    /// ```motoko
    /// switch (stableGateway) { case (?d) { gate.loadStable(d) }; case (null) {} };
    /// switch (gate.setEvmDerivationPath(PATH)) { case (#ok) {}; case (#err(e)) { Debug.trap(e) } };
    /// ```
    /// The restored recipient does not refuse this first re-apply, because the setter cannot
    /// tell which path derived it. The derive that `startTimers` arms checks it instead: when
    /// the restored recipient is not the address the path derives, it stops every EVM send
    /// (refused before signing) and logs why, until an upgrade re-applies the right path. Once
    /// a path is applied, or a derive has begun under it, the refusal above applies.
    public func setEvmDerivationPath(derivationPath : [Blob]) : { #ok; #err : Text } {
      switch (SchnorrSigner.validateDerivationPath(derivationPath)) {
        case (#err(e)) { return #err(e) };
        case (#ok) {};
      };
      switch (evmRecipient) {
        case (?addr) {
          // Unpinned, the path is the transient default after an upgrade and this recipient was
          // restored by loadStable: accept the deployment's path (deriveCurrent checks it).
          if (evmPathPinned and not pathsEqual(derivationPath, evmDerivationPath)) {
            return #err(
              "recipient already derived as " # addr
              # " under a different path; a published recipient cannot move"
            );
          };
        };
        case (null) {};
      };
      evmPathPinned := true;
      // 2.22.0: re-applying the path the gateway is already on keeps the sender. Rebuilding it
      // dropped its single-flight send lock mid-send (two sends could then pick one nonce), its
      // broadcast-authorization guard and its sent-tx nonce memory.
      if (pathsEqual(derivationPath, evmDerivationPath)) {
        switch (evmSenderInst) { case (?_) { return #ok }; case (null) {} };
      };
      evmDerivationPath := derivationPath;
      evmSenderInst := switch (config.ecdsaKeyName) {
        case (?keyName) {
          switch (EvmSender.EvmSenderAt(keyName, config.evmRpcCanister, derivationPath)) {
            case (#ok(snd)) { ?snd };
            case (#err(e)) { return #err(e) };
          };
        };
        case (null) { null };
      };
      #ok;
    };

    /// The path this gateway's EVM keys derive under. `[]` is the default.
    public func getEvmDerivationPath() : [Blob] { evmDerivationPath };

    func pathsEqual(a : [Blob], b : [Blob]) : Bool {
      if (a.size() != b.size()) { return false };
      var i = 0;
      while (i < a.size()) {
        if (a[i] != b[i]) { return false };
        i += 1;
      };
      true;
    };

    var receiptCounter : Nat = 0;
    // 2.21.0 (default OFF): see setLedgerDedup. Transient: re-apply at init.
    var ledgerDedup = false;
    // 2.24.0: the operator's ceiling on a split payee's finder share, in basis points (see
    // setEvmSplitCeiling); null = settleToSplit refuses every payment. Transient, like
    // setLedgerDedup: re-apply after an upgrade.
    var evmSplitCeilingBps : ?Nat = null;
    // Self-derived EVM address (from tECDSA key). Populated by deriveEvmRecipient().
    var evmRecipient : ?Text = null;
    // Live EVM chain set (see setEvmChains). Starts as the constructor config's evmChains;
    // every Gateway chain lookup (findEvmChain, requireEvm, describeAll, supportedJson) reads
    // THIS, never config.evmChains, so a runtime swap takes effect for new requests.
    var liveEvmChains : [Types.EvmChainConfig] = config.evmChains;
    // 2.22.0 (E4): fail closed on a chain whose tokens have different decimals — construction
    // traps (install/upgrade fails with this message) rather than run a rail a payer can underpay.
    switch (checkEvmTokenDecimals(config.evmChains)) {
      case (#err(e)) { Debug.trap("ic402: config.evmChains: " # e) };
      case (#ok) {};
    };

    // SEC-1: a GLOBAL (caller-agnostic) admission gate for the UNAUTHENTICATED facilitator update
    // endpoints (POST /verify, /settle). The per-caller policy rate limit is bypassable — an
    // attacker varies the EVM `from`/derived principal to mint fresh buckets — so this is keyed on
    // NOTHING: one shared token bucket caps the TOTAL facilitator-update rate, plus a cycle floor
    // so the canister stops doing attacker-triggerable ecrecover/RPC/sign work well before it can
    // be drained toward the freezing threshold. Transient (resets full on upgrade).
    let FACILITATOR_BUCKET_CAPACITY : Nat = 60; // burst allowance
    let FACILITATOR_REFILL_PER_SEC : Nat = 2; // 120/min sustained, GLOBAL
    let FACILITATOR_MIN_CYCLES : Nat = 500_000_000_000; // refuse facilitator work below ~500B
    var facilitatorTokens : Nat = 60;
    var facilitatorLastRefill : Int = 0;

    /// Pure rate-limit admission (token bucket only, NO cycle floor). SEC-0: settle/verifyPayment
    /// call this to meter the expensive ecRecover without depending on Cycles.balance() (which is
    /// unavailable in the unit-test interpreter) and without the 500B floor blocking legitimate
    /// settlement at merely-moderate cycles. The GLOBAL (caller-agnostic) bucket bounds the
    /// aggregate rate of attacker-triggerable ecRecover; the cycle floor stays in facilitatorAdmit
    /// (the pure-facilitator /verify+/settle endpoints) and in EvmSender's 120B broadcast floor.
    func admitRate() : { #ok; #throttled } {
      let step = tokenBucketStep(facilitatorTokens, facilitatorLastRefill, Time.now(), FACILITATOR_BUCKET_CAPACITY, FACILITATOR_REFILL_PER_SEC);
      facilitatorTokens := step.tokens;
      facilitatorLastRefill := step.lastRefill;
      if (step.admit) { #ok } else { #throttled };
    };

    /// SEC-1 gate — call BEFORE parsing the facilitator body or running verifyPayment/settle.
    /// Returns #throttled when the global rate is exceeded, #lowCycles when the balance is below
    /// the floor (so an attacker can't drain the canister via the unmetered facilitator path).
    public func facilitatorAdmit() : { #ok; #throttled; #lowCycles } {
      if (Cycles.balance() < FACILITATOR_MIN_CYCLES) { return #lowCycles };
      admitRate();
    };

    /// SEC-0 (round 2): just the cycle floor (no bucket). A consumer applies this at its HTTP
    /// facilitator ingress for the low-cycles 503 backstop, while the per-request RATE limit now
    /// lives INSIDE settle/verifyPayment/openSession (admitRate). Using this instead of
    /// facilitatorAdmit on those routes avoids charging the global bucket twice per request.
    public func cyclesBelowFloor() : Bool { Cycles.balance() < FACILITATOR_MIN_CYCLES };

    /// 2.23.1: lift every EVM payer cooldown. A payer whose sent inbound transfer reverted is refused
    /// for an hour, or 5 minutes when it had not confirmed or another transaction executed its
    /// authorization (EvmSender.PayerGuard); an operator can lift that early, e.g. for a payer whose
    /// funds moved by mistake. Returns how many payers were
    /// cooling down (expired entries included). OPERATOR op: a consumer must restrict it to its
    /// controllers. Settle and the session open share the one guard, so this lifts both.
    public func clearEvmPayerCooldowns() : Nat {
      switch (evmSenderInst) {
        case (?s) { s.inFlightPayers.clearCooldowns() };
        case (null) { 0 };
      };
    };

    /// 2.23.1: lift one EVM payer's cooldown (see clearEvmPayerCooldowns), for `from` paying in
    /// `token` on `chainId`. True when it was cooling down. OPERATOR op: restrict to controllers.
    public func liftEvmPayerCooldown(chainId : Nat, token : Text, from : Text) : Bool {
      switch (evmSenderInst) {
        case (?s) {
          s.inFlightPayers.liftCooldown(s.inFlightPayers.key(chainId, token, EvmUtils.hexToBytes(from)), Int.abs(Time.now() / 1_000_000_000));
        };
        case (null) { false };
      };
    };

    /// 2.23.2: lift the gas stop on `chainId`. When a broadcast on a chain reports that the
    /// canister's EVM address cannot pay the gas, every send on that chain is refused before signing
    /// for 10 minutes (EvmSender.GasStops): inbound payments and session deposits (before their
    /// simulation), and closes, refunds, sweeps and payouts. A timer close refused by the stop
    /// reopens the session, and the job sweep keeps a refused payout uncounted; both are retried
    /// each tick with no outcall until the stop ends (EvmSender.sendCanWait). The send that set the
    /// stop was signed, so it is handled as any failure (a timer close parks, a payout counts); its
    /// error names the signed tx to check. Lift only once the top-up is confirmed: the next send
    /// signs. True when a stop was in force. OPERATOR op: a consumer must restrict it to its
    /// controllers.
    public func liftEvmGasStop(chainId : Nat) : Bool {
      switch (evmSenderInst) {
        case (?s) { s.gasStops.lift(chainId, Int.abs(Time.now() / 1_000_000_000)) };
        case (null) { false };
      };
    };

    // 2.22.0 (E3): Sessions reads the sender through a getter, like the recipient, so it always
    // uses the CURRENT one. It was handed the construction-time sender, which setEvmDerivationPath
    // then replaced — so session deposits, closes and reconciles signed from the empty-path address
    // while charges signed from the new one. `null` here: the getter is the only source.
    let sessionsMgr = SessionsMod.Sessions(
      selfPrincipal, config, policy, escrowManager,
      evmEscrowMgr, null,
      { get = func() : ?Text { evmRecipient } },
    );
    sessionsMgr.setEvmSenderSource(func() : ?EvmSender.EvmSender { evmSenderInst });
    // SEC-0 (round 2): share the global facilitator token bucket with the session-open path, so the
    // expensive ecRecover in openEvmSession is rate-limited by the SAME caller-agnostic gate as
    // settle/verifyPayment — not just the mintable per-caller policy limit.
    sessionsMgr.setAdmitRate(admitRate);

    // Management canister for tECDSA
    let management_canister : actor {
      ecdsa_public_key : shared {
        key_id : { name : Text; curve : { #secp256k1 } };
        canister_id : ?Principal;
        derivation_path : [Blob];
      } -> async {
        public_key : Blob;
        chain_code : Blob;
      };
    } = actor "aaaaa-aa";

    /// Derive the canister's EVM address from its tECDSA public key.
    /// Call once after deployment (e.g., from a timer). The result is cached
    /// and persisted across upgrades via stable state.
    ///
    /// ecdsaKeyName: "dfx_test_key" for local replica, "key_1" for mainnet IC.
    /// A recipient restored by loadStable that the current path does not derive stops every EVM
    /// send, as the derive startTimers arms does (see setEvmDerivationPath).
    public func deriveEvmRecipient(ecdsaKeyName : Text) : async () {
      // Derives under the gateway's CURRENT path, which defaults to [] — so a consumer that
      // never calls setEvmDerivationPath gets byte-identical pre-2.16.0 behaviour, and one
      // that does cannot accidentally derive the recipient off the sender's path.
      // 2.18.1: inline (`await*`) — no inner self-call hop (deriveRecipient) before the management
      // call; this function's own `async` hop remains (its signature is public).
      await* deriveCurrent(ecdsaKeyName);
    };

    // The derive under the CURRENT path (startTimers' install timer, deriveEvmRecipient). A path
    // setEvmDerivationPath moved during the derive is derived again. A recipient the path does not
    // derive (or whose check failed) stops every EVM send: the sender would sign from an address
    // the deposits never reach. Only an upgrade clears the stop, since the path is pinned by now.
    func deriveCurrent(ecdsaKeyName : Text) : async* () {
      loop {
        let path = evmDerivationPath;
        switch (await* deriveRecipientCore(ecdsaKeyName, path)) {
          case (#ok) { return };
          case (#err(e)) {
            if (pathsEqual(path, evmDerivationPath)) {
              switch (evmRecipient, evmSenderInst) {
                case (?_, ?sender) {
                  let reason = e # ". Re-apply the path that derived it with setEvmDerivationPath, after loadStable, and upgrade";
                  sender.stopSends(reason);
                  Debug.print("ic402 CRITICAL: EVM sends stopped: " # reason);
                };
                case (_) {};
              };
              return;
            };
          };
        };
      };
    };

    /// Derive the inbound EVM recipient under an explicit derivation path, validated.
    ///
    /// INVARIANT — THE SAME PATH EVERYWHERE. This address is what payers are told to send
    /// to. The `EvmSigner` that spends from it and the `EvmSender` that settles outbound
    /// must be constructed under THIS SAME PATH. Derive the recipient under one path and
    /// sign under another and the canister signs from an address nothing funds, while
    /// deposits pile up at an address it never spends from.
    ///
    /// The recipient is a single persisted slot (`StableGatewayState.evmRecipient`), so the
    /// first successful derivation wins and later calls return early — a gateway has ONE
    /// recipient. Choose the path before publishing it; a published address cannot move.
    public func deriveEvmRecipientAt(
      ecdsaKeyName : Text,
      derivationPath : [Blob],
    ) : async { #ok; #err : Text } {
      switch (SchnorrSigner.validateDerivationPath(derivationPath)) {
        case (#err(e)) { return #err(e) };
        case (#ok) {};
      };
      // The outbound sender must already be on this path, or settling would sign from an
      // address the deposits never reach. Refuse rather than create that split.
      if (not pathsEqual(derivationPath, evmDerivationPath)) {
        return #err(
          "gateway's EVM sender is on a different derivation path; "
          # "call setEvmDerivationPath first so the recipient and the sender are one address"
        );
      };
      try { await deriveRecipient(ecdsaKeyName, derivationPath) } catch (e) {
        #err("EVM recipient derivation failed: " # Error.message(e));
      };
    };

    // Shared body. Returns early when already derived — the slot is persisted and a
    // gateway's recipient must never move once payers have it.
    // deriveEvmRecipientAt keeps this separate message (its try/catch turns any failure, a trap
    // included, into #err); the install timer and deriveEvmRecipient run the body inline.
    func deriveRecipient(ecdsaKeyName : Text, derivationPath : [Blob]) : async {
      #ok;
      #err : Text;
    } {
      await* deriveRecipientCore(ecdsaKeyName, derivationPath);
    };

    // 2.18.1: the body, as `async*`. Nothing before its first await can trap.
    func deriveRecipientCore(ecdsaKeyName : Text, derivationPath : [Blob]) : async* {
      #ok;
      #err : Text;
    } {
      // A derive commits this lifetime to the path: a recipient now pins it (setEvmDerivationPath).
      evmPathPinned := true;
      switch (evmRecipient) {
        // Already derived. Do NOT report a bare #ok: the slot is persisted, so on any
        // gateway upgraded from <=2.15.0 it already holds the EMPTY-path address, and a
        // caller asking for a labelled path would read that #ok as "your path was applied"
        // and then publish one address while signing for another. Confirm the existing
        // recipient IS the one this path derives, and say so plainly when it is not.
        case (?existing) {
          let check = await management_canister.ecdsa_public_key({
            key_id = { name = ecdsaKeyName; curve = #secp256k1 };
            canister_id = null;
            derivation_path = derivationPath;
          });
          switch (EvmAddress.fromCompressedPublicKey(Blob.toArray(check.public_key))) {
            case (#ok(addr)) {
              if (addr == existing) { return #ok };
              return #err(
                "recipient already derived as " # existing
                # " under a different path; a published recipient cannot move"
              );
            };
            case (#err(msg)) { return #err("EVM address derivation failed: " # msg) };
          };
        };
        case (null) {};
      };
      let result = await management_canister.ecdsa_public_key({
        key_id = { name = ecdsaKeyName; curve = #secp256k1 };
        canister_id = null;
        derivation_path = derivationPath;
      });
      // With no recipient, setEvmDerivationPath may have moved the path (and the sender) during the
      // await. Recording this address would put the recipient on the old path: record nothing.
      if (not pathsEqual(derivationPath, evmDerivationPath)) {
        return #err("the gateway's derivation path changed during the derive; nothing was recorded — derive again");
      };
      // H-2: Surface error instead of silently swallowing — operators can see this in canister logs
      switch (EvmAddress.fromCompressedPublicKey(Blob.toArray(result.public_key))) {
        case (#ok(addr)) { evmRecipient := ?addr; #ok };
        case (#err(msg)) {
          Debug.print("ic402 CRITICAL: EVM address derivation failed: " # msg # ". EVM payments will be unavailable.");
          #err("EVM address derivation failed: " # msg);
        };
      };
    };

    /// Get the self-derived EVM recipient address, if available.
    public func getEvmRecipient() : ?Text {
      evmRecipient;
    };

    func nextReceiptId() : Text {
      receiptCounter += 1;
      "rcpt-" # Nat.toText(receiptCounter);
    };

    // The account payers and operators SEE: the 402 `recipient`/`payTo` field and receipt
    // stamps. ICRC-1 textual encoding, so a configured subaccount is part of the advertised
    // identity — for a null (or all-zero) subaccount this is byte-identical to the bare owner
    // principal; otherwise `<owner>-<checksum>.<subaccount-hex>`, the SAME account
    // recipientAccount() settles into. Before 2.12.0 this dropped the subaccount, so payTo and
    // receipts named an account (owner, default subaccount) that funds never touched. Note no
    // ICP fund movement is ever DIRECTED by this text — settle is an ICRC-2 pull to
    // recipientAccount() — so the old behaviour was an advertisement/receipt integrity bug,
    // not a misdelivery path; but anything reconciling against payTo or auditing receipts got
    // the wrong account whenever a subaccount was configured.
    func recipientText() : Text {
      Utils.icrc1AccountText(config.recipient.owner, config.recipient.subaccount);
    };

    func recipientAccount() : Types.Account {
      { owner = config.recipient.owner; subaccount = config.recipient.subaccount };
    };

    func findLedger(identifier : Text) : ?Types.TokenConfig {
      Utils.findLedger(config.tokens, identifier);
    };

    /// Nonce expiry in nanoseconds, from config or default (5 minutes).
    func nonceExpiryNanos() : Int {
      let seconds = switch (config.nonceExpirySeconds) {
        case (?s) { s };
        case (null) { 300 };
      };
      seconds * 1_000_000_000;
    };

    // ── Convenience helpers ──

    /// Construct an ICP Price from the first configured token.
    /// Returns null if no ICP tokens are configured.
    public func price(amount : Nat) : ?Types.Price {
      if (config.tokens.size() == 0) return null;
      ?{
        token = config.tokens[0].ledger;
        amount;
        network = "icp:1";
      };
    };

    /// Generate ICP + all EVM payment requirements in one call.
    /// Returns ICP-only, EVM-only, or both depending on config.
    public func requireAll(amount : Nat) : [Types.PaymentRequirement] {
      let evmReqs = requireEvm(amount);
      switch (price(amount)) {
        case (?p) { Array.append([require(p)], evmReqs) };
        case (null) { evmReqs };
      };
    };

    /// Check whether the self-derived EVM address is available.
    /// Returns false until startTimers() completes the tECDSA derivation.
    public func isEvmReady() : Bool {
      switch (evmRecipient) {
        case (?_) { true };
        case (null) { false };
      };
    };

    // ── Charge (x402 "exact") ──

    /// Generate a 402 payment requirement for a given price.
    /// Traps if amount is 0 to prevent free-payment attacks.
    public func require(price : Types.Price) : Types.PaymentRequirement {
      if (price.amount == 0) { Debug.trap("ic402: require() called with amount = 0; payment amount must be positive") };
      let expiry = Time.now() + nonceExpiryNanos();
      let tokenText = Principal.toText(price.token);
      let nonce = nonceManager.generate(expiry, price.amount, price.network, tokenText);
      {
        scheme = "exact";
        network = price.network;
        token = tokenText;
        amount = price.amount;
        recipient = recipientText();
        nonce;
        expiry;
        tokenName = null;
        tokenVersion = null;
      };
    };

    /// Look up an EVM chain config by chain ID (in the LIVE set — see setEvmChains).
    func findEvmChain(chainId : Nat) : ?Types.EvmChainConfig {
      for (chain in liveEvmChains.values()) {
        if (chain.chainId == chainId) return ?chain;
      };
      null;
    };


    /// Resolve the EVM recipient: prefer self-derived address, fall back to config.
    func evmRecipientFor(chain : Types.EvmChainConfig) : Text {
      switch (evmRecipient) {
        case (?addr) { addr };
        case (null) { chain.recipient };
      };
    };

    /// Generate 402 payment requirements for all configured EVM chains.
    /// M-7: Traps if amount is 0 to prevent free-payment attacks.
    /// One requirement per chain, using the chain's FIRST configured token only. Additional
    /// configured tokens on a chain are still settleable when the client echoes them via
    /// PaymentSignature.asset, but are not advertised by this helper — build custom
    /// PaymentRequirements for them if you want them offered.
    public func requireEvm(amount : Nat) : [Types.PaymentRequirement] {
      if (amount == 0) { Debug.trap("ic402: requireEvm() called with amount = 0; payment amount must be positive") };
      let buf = Buffer.Buffer<Types.PaymentRequirement>(liveEvmChains.size());
      for (chain in liveEvmChains.values()) {
        // Skip chains with no tokens configured
        if (chain.tokens.size() == 0) { /* skip */ } else {
        let expiry = Time.now() + nonceExpiryNanos();
        let tok = chain.tokens[0];
        let network = "eip155:" # Nat.toText(chain.chainId);
        let nonce = nonceManager.generate(expiry, amount, network, tok.address);
        buf.add({
          scheme = "exact";
          network;
          token = tok.address;
          amount;
          recipient = evmRecipientFor(chain);
          nonce;
          expiry;
          tokenName = tok.name;
          tokenVersion = tok.version;
        });
        };
      };
      Buffer.toArray(buf);
    };

    func isEvmNetwork(network : Text) : Bool {
      Utils.isEvmNetwork(network);
    };

    // ── x402 facilitator / discovery (advertising) ──

    /// Non-minting payment requirements for ADVERTISING (discovery / Bazaar). Unlike
    /// require*, this does NOT generate or persist a server nonce — it describes the price/asset
    /// for each rail so a client can discover the endpoint. The client must still hit the
    /// resource to receive a live 402 challenge with a real nonce. nonce = empty, expiry = 0.
    /// One requirement per chain, using the chain's FIRST configured token only. Additional
    /// configured tokens on a chain are still settleable when the client echoes them via
    /// PaymentSignature.asset, but are not advertised by this helper — build custom
    /// PaymentRequirements for them if you want them offered.
    public func describeAll(amount : Nat) : [Types.PaymentRequirement] {
      let buf = Buffer.Buffer<Types.PaymentRequirement>(liveEvmChains.size() + 1);
      switch (price(amount)) {
        case (?p) {
          buf.add({
            scheme = "exact"; network = p.network; token = Principal.toText(p.token);
            amount = p.amount; recipient = recipientText();
            nonce = Blob.fromArray([]); expiry = 0; tokenName = null; tokenVersion = null;
          });
        };
        case (null) {};
      };
      for (chain in liveEvmChains.values()) {
        if (chain.tokens.size() == 0) { /* skip */ } else {
          let tok = chain.tokens[0];
          buf.add({
            scheme = "exact"; network = "eip155:" # Nat.toText(chain.chainId);
            token = tok.address; amount; recipient = evmRecipientFor(chain);
            nonce = Blob.fromArray([]); expiry = 0; tokenName = tok.name; tokenVersion = tok.version;
          });
        };
      };
      Buffer.toArray(buf);
    };

    /// Resolve the (token, recipient) for opening an EVM session on `network` ("eip155:<chainId>"):
    /// the chain's first configured USDC and the canister's own derived EVM address. Returns null
    /// if the network is malformed, the chain/token isn't configured, or the EVM address isn't
    /// derived yet — so a consumer can build a SessionIntent honouring the client's EVM rail
    /// instead of forcing ICP.
    public func evmSessionParams(network : Text) : ?{ token : Text; recipient : Text } {
      switch (extractChainId(network)) {
        case (null) { null };
        case (?chainId) {
          switch (findEvmChain(chainId)) {
            case (?chain) {
              if (chain.tokens.size() == 0) { null } else {
                switch (evmRecipient) {
                  case (?addr) { ?{ token = chain.tokens[0].address; recipient = addr } };
                  case (null) { null };
                };
              };
            };
            case (null) { null };
          };
        };
      };
    };

    /// x402 v2 `GET /supported` body: the (x402Version, scheme, network) kinds this facilitator
    /// can settle, plus the on-chain signer(s). Only the STANDARD EVM (`eip155:*`, `exact`) kinds
    /// are advertised — the ICP rail is non-standard and intentionally omitted so a strict v2
    /// client/facilitator sees only what it can interoperate with. `signers` maps the CAIP-2 EVM
    /// namespace to the canister's own tECDSA-derived EVM address (the entity that broadcasts).
    public func supportedJson() : Text {
      var kinds = "";
      var first = true;
      for (chain in liveEvmChains.values()) {
        if (chain.tokens.size() == 0) { /* skip */ } else {
          if (not first) { kinds #= "," };
          kinds #= "{\"x402Version\":2,\"scheme\":\"exact\",\"network\":\"eip155:" # Nat.toText(chain.chainId) # "\"}";
          first := false;
        };
      };
      let signer = switch (evmRecipient) { case (?a) { a }; case (null) { "" } };
      "{\"kinds\":[" # kinds # "],\"extensions\":[],\"signers\":{\"eip155:*\":[\"" # signer # "\"]}}";
    };

    /// x402 v2 facilitator `POST /verify`: validate an exact/EVM PaymentPayload against the chosen
    /// PaymentRequirements OFF-CHAIN: no nonce is minted or consumed, nothing is broadcast, and no
    /// payment state changes. It DOES consume one token from the GLOBAL facilitator rate
    /// bucket shared with settle/openSession (the ecRecover here is the same cycle-DoS
    /// surface) — heavy verify traffic can throttle settlement, and a
    /// `invalidReason = "rate_limited"` result is transient, not a signature failure. Returns
    /// the v2 verify verdict {isValid, invalidReason?, payer?}. EVM-only — the ICP rail is
    /// non-standard and not exposed as a facilitator scheme. `asset` is the requirement's
    /// token (EIP-712 verifyingContract); name/version come from the per-chain config.
    public func verifyPayment(signature : Types.PaymentSignature, expectedAmount : Nat, payTo : Text, asset : Text) : {
      isValid : Bool;
      invalidReason : ?Text;
      payer : ?Text;
    } {
      if (not isEvmNetwork(signature.network)) {
        return { isValid = false; invalidReason = ?"unsupported_scheme"; payer = null };
      };
      // SEC-0: rate-limit the expensive ecRecover below behind the global token bucket —
      // verifyPayment runs pure-Motoko ecRecover on attacker input, the same cycle-DoS surface as
      // settle. Self-protecting so a consumer that calls verifyPayment need not gate it externally.
      switch (admitRate()) {
        case (#ok) {};
        case (#throttled) { return { isValid = false; invalidReason = ?"rate_limited"; payer = null } };
      };
      let authz = switch (signature.authorization) {
        case (?a) { a };
        case (null) { return { isValid = false; invalidReason = ?"invalid_payload"; payer = null } };
      };
      // 2.22.0: fields the chain could not hold are refused, not truncated (EvmUtils.eip3009FieldsFit).
      if (not EvmUtils.eip3009FieldsFit(authz.value, authz.validAfter, authz.validBefore, Blob.toArray(authz.nonce))) {
        return { isValid = false; invalidReason = ?"invalid_payload"; payer = ?authz.from };
      };
      let nowSeconds = Int.abs(Time.now() / 1_000_000_000);
      if (nowSeconds < authz.validAfter) {
        return { isValid = false; invalidReason = ?"invalid_exact_evm_payload_authorization_valid_after"; payer = ?authz.from };
      };
      // 2.22.0: strict, as the token checks it (block.timestamp < validBefore) — at nowSeconds ==
      // validBefore the transfer can only revert. (validAfter stays non-strict: the tx mines
      // seconds after this check, by when the chain's strict validAfter < block.timestamp holds.)
      // 2.23.1: and it must stay valid long enough to land, as settle requires
      // (EvmSender.MIN_VALIDITY_SECONDS), so /verify does not pass what /settle refuses.
      if (EvmSender.expiresTooSoon(authz.validBefore, nowSeconds)) {
        return { isValid = false; invalidReason = ?"invalid_exact_evm_payload_authorization_valid_before"; payer = ?authz.from };
      };
      if (not EvmUtils.addressesEqual(authz.to, payTo)) {
        return { isValid = false; invalidReason = ?"invalid_exact_evm_payload_recipient_mismatch"; payer = ?authz.from };
      };
      if (authz.value != expectedAmount) {
        return { isValid = false; invalidReason = ?"invalid_exact_evm_payload_authorization_value_mismatch"; payer = ?authz.from };
      };
      let chainId = switch (extractChainId(signature.network)) {
        case (?id) { id };
        case (null) { return { isValid = false; invalidReason = ?"invalid_network"; payer = ?authz.from } };
      };
      // Resolve the EIP-712 domain (name/version) from the token actually being paid
      // (`asset` is the verifyingContract passed to verifyAuthorization below), NOT
      // tokens[0]: on a multi-token chain they differ and a wrong domain makes a
      // valid signature fail to verify. Reject an asset this canister doesn't accept.
      let (tokenName, tokenVersion) = switch (findEvmChain(chainId)) {
        case (null) { return { isValid = false; invalidReason = ?"invalid_network"; payer = ?authz.from } };
        case (?chain) {
          switch (resolveEvmDomain(chain, asset)) {
            case (?d) { (d.name, d.version) };
            case (null) { return { isValid = false; invalidReason = ?"unsupported_asset"; payer = ?authz.from } };
          };
        };
      };
      let verified = Eip712.verifyAuthorization(
        chainId, EvmUtils.hexToBytes(asset),
        EvmUtils.hexToBytes(authz.from), EvmUtils.hexToBytes(authz.to),
        authz.value, authz.validAfter, authz.validBefore,
        Blob.toArray(authz.nonce), authz.v, Blob.toArray(authz.r), Blob.toArray(authz.s),
        tokenName, tokenVersion,
      );
      if (not verified) {
        return { isValid = false; invalidReason = ?"invalid_exact_evm_payload_authorization_signature"; payer = ?authz.from };
      };
      { isValid = true; invalidReason = null; payer = ?authz.from };
    };

    func extractChainId(network : Text) : ?Nat {
      Utils.extractChainId(network);
    };

    /// Resolve the token for nonce binding from the signature's network.
    func resolveTokenForNonce(network : Text) : Text {
      if (isEvmNetwork(network)) {
        switch (extractChainId(network)) {
          case (?cid) {
            switch (findEvmChain(cid)) {
              case (?cc) { if (cc.tokens.size() > 0) cc.tokens[0].address else "" };
              case (null) { "" };
            };
          };
          case (null) { "" };
        };
      } else {
        switch (findLedger(network)) {
          case (?tc) { Principal.toText(tc.ledger) };
          case (null) {
            if (config.tokens.size() > 0) Principal.toText(config.tokens[0].ledger) else "";
          };
        };
      };
    };

    /// Verify and settle a charge payment (ICP via ICRC-2, or EVM via EIP-3009 broadcast + confirm).
    ///
    /// `expectedAmount` is the price the calling resource advertised. It is REQUIRED for a
    /// conformant x402 client that sends no ic402 server nonce (the EVM rail), and serves as a
    /// cross-resource guard for server-nonce clients. Pass `null` to fall back to the nonce-bound
    /// amount. ICP settlement ALWAYS requires the server nonce (empty nonce → #expired).
    ///
    /// Nonce lifecycle: lock → (awaits) → consume on #ok / unlock on failure, EXCEPT
    /// #settlementPending, where the nonce stays LOCKED so the same challenge cannot be
    /// re-broadcast. The nonce clean-up removes it some time after it expires: the clean-up runs
    /// once the table holds 10,000 live nonces or 20,000 have been issued, and anyone can request
    /// challenges. 2.21.0: a nonce holding a stored pending transfer is kept for 24 hours past its
    /// expiry (setLedgerDedup). #settlementPending is NOT final: no receipt is issued and the
    /// caller MUST NOT deliver value — the broadcast tx may still mine later (handle out-of-band).
    /// 2.20.0: the ICP rail returns #settlementPending too, when the ledger call is rejected after
    /// it may have run (Utils.rejectedBeforeExecution is false): the payer may have been charged.
    /// Do not deliver, do not re-submit; check the ledger before taking a new payment. A reject
    /// the system raised before the ledger ran is still #settlementFailed (nonce unlocked).
    /// 2.21.0, with setLedgerDedup on: a pending ICP charge made through settleFrom is resolved by
    /// the payer calling settleFrom again with the SAME payment (one receipt, never a second charge).
    /// 2.22.0: a payment whose nonce another settle for a DIFFERENT payer still holds in flight
    /// gets #policyDenied("A settlement with this payment is already in progress — …"): nothing of
    /// this payer's is known to have moved; retry the same payment shortly. #settlementPending
    /// means the unknown outcome above (including any lock restored by loadStable), or a settle for
    /// the SAME payer (ICP sender; EVM authorization `from`) still in flight — a client's re-send
    /// must not pay again while its first attempt may be pulling the funds. A pending ICP charge
    /// made over `settle` (HTTP) releases the named sender's daily reservation; one made through
    /// settleFrom keeps it. The clean-up also keeps a nonce whose settlement is still in flight for
    /// 24 hours past its expiry.
    ///
    /// Multi-token (v2.5.0): the EVM verify + on-chain execution key off `signature.asset`
    /// (the EIP-712 verifyingContract the payer signed for); `asset = null` falls back to the
    /// chain's FIRST configured token. EVM additionally requires authorization.to == the
    /// canister's derived EVM address and authorization.value == the settled amount (exact).
    ///
    /// 2.22.0, EVM: an authorization this canister already broadcast is not broadcast again —
    /// #settlementPending naming the earlier tx (EvmSender.AuthorizationGuard). A transfer that
    /// reverts is checked against the token's authorizationState: still unused → #settlementFailed
    /// (no funds moved); used (another tx executed it, or the payer cancelled it) or unreadable →
    /// #settlementPending (funds may have arrived; no receipt). validBefore is strict, as on chain.
    ///
    /// 2.23.1, EVM: before anything is signed, the transfer is simulated (an eth_call made as the
    /// broadcast would run). Refused without signing: an authorization with under 120 s left
    /// (#expired); a payer with another transfer still settling (#policyDenied, "retry this same
    /// payment"); a payer cooling down after its sent transfer reverted (an hour) or did not confirm
    /// within the polls (5 minutes) (#policyDenied, final for now); and as #settlementFailed — the
    /// canister below 500B cycles, a spent check budget, or a simulation that
    /// reverts (final) or gives no agreed answer ("retry this same payment"). 2.23.2: also as
    /// #settlementFailed, final for now, a chain the canister could not pay gas on in the last 10
    /// minutes (EvmSender.GasStops, "This canister cannot pay gas on chain …"). Nothing of any of
    /// these was sent. See EvmSender's "Simulate before signing".
    ///
    /// Interleaving: this method awaits (EVM broadcast + confirmation poll / ICP ledger call).
    /// The nonce lock and the daily-spend reservation commit synchronously BEFORE the first
    /// await and are rolled back on failure; the per-caller rate hit is checked read-only before
    /// it and recorded only with a receipt (I6). EVM settles are metered by the GLOBAL facilitator
    /// token bucket and can return #policyDenied("Rate limited…") under load; ICP settles are not.
    public func settle(signature : Types.PaymentSignature, expectedAmount : ?Nat) : async Types.PaymentResult {
      await* settleCore(signature, expectedAmount, false, null);
    };

    /// 2.24.0: settle an EVM charge the payer sent to a split payee instead of to this canister:
    /// the 0xSplits push split (v2.2, no owner) paying `split.finder` its `split.finderShareBps`
    /// (basis points of 10,000) and this canister's EVM address the rest (EvmSplits). The canister
    /// recomputes that split's address and accepts the payment only when the authorization's `to`
    /// is exactly it. Everything else is `settle`: the signature, the exact amount, the simulation,
    /// the payer slot, the gas stop, the confirmation. The receipt's `recipient` is the split, and
    /// its `amount` the full payment; this canister's share arrives when someone distributes the
    /// split (ic402 does not deploy or distribute splits).
    ///
    /// Refused before anything is signed (#policyDenied): split payees off (no ceiling, see
    /// setEvmSplitCeiling), a chain other than Base and Base Sepolia, a share of 0 or above the
    /// ceiling, a zero-address finder, or the paid token as finder. A `to` that is not that split:
    /// #invalidSignature. ICP: #networkNotSupported.
    ///
    /// TRUSTED CALLER ONLY: take the finder and share from your own records (the referral codes
    /// you honour), never from the payment or the request, or any payer can name itself finder and
    /// take the share as a discount. Do not expose it on a public facilitator route. Not for
    /// session deposits, which must reach the canister's own address. NOT FOR JOBS: never pass its
    /// receipt to ServiceRegistry.createJobFromReceipt or submitRequest. The receipt's amount is the
    /// full payment, but only the seller's share reaches the canister (later), so a job refund or
    /// payout would pay the difference out of other funds.
    public func settleToSplit(signature : Types.PaymentSignature, expectedAmount : ?Nat, split : EvmSplits.SplitPayee) : async Types.PaymentResult {
      if (not isEvmNetwork(signature.network)) {
        return #networkNotSupported("settleToSplit is for EVM payments only, not " # signature.network);
      };
      await* settleCore(signature, expectedAmount, false, ?split);
    };

    /// 2.24.0: set the ceiling on a split payee's finder share, in basis points (1 to 9,999), or
    /// null to turn split payees off (the default). settleToSplit refuses a share above it. It also
    /// bounds the discount a buyer gets by referring itself. Transient: re-apply after an upgrade.
    /// OPERATOR op: a consumer must restrict it to its controllers.
    public func setEvmSplitCeiling(bps : ?Nat) : { #ok; #err : Text } {
      switch (bps) {
        case (?b) {
          if (b == 0 or b >= EvmSplits.TOTAL_ALLOCATION) {
            return #err("The ceiling must be between 1 and 9999 basis points (the seller keeps the rest), or null to turn split payees off");
          };
        };
        case (null) {};
      };
      evmSplitCeilingBps := bps;
      #ok;
    };

    /// 2.24.0: the ceiling setEvmSplitCeiling set; null while split payees are off.
    public func evmSplitCeiling() : ?Nat { evmSplitCeilingBps };

    // The body of `settle`, shared with settleFrom as `async*` so neither adds a self-send hop.
    // `payerIsCaller`: true only from settleFrom, which has checked that the caller is the named
    // sender. 2.21.0: only then is a pending charge's transfer stored or re-sent (setLedgerDedup).
    // `split`: 2.24.0, settleToSplit's split payee; null = the payment must be to this canister.
    func settleCore(signature : Types.PaymentSignature, expectedAmount : ?Nat, payerIsCaller : Bool, split : ?EvmSplits.SplitPayee) : async* Types.PaymentResult {
      // SEC-0: rate-limit the EXPENSIVE EVM verify path (pure-Motoko ecRecover over attacker-
      // controlled EIP-3009 input) behind the GLOBAL token bucket, so an unauthenticated flood of
      // bogus payloads on ANY paid path (/content, /search, /settle) cannot run unmetered ecRecover
      // toward the freezing threshold. settle is now self-protecting regardless of which resource
      // path the consumer routes from — the SEC-1 metering no longer depends on the consumer
      // remembering to call facilitatorAdmit. ICP settles (cheap inter-canister calls) are NOT gated.
      if (isEvmNetwork(signature.network)) {
        switch (admitRate()) {
          case (#ok) {};
          case (#throttled) { return #policyDenied("Rate limited: global facilitator admission bucket exhausted (shared across settle/verify/session-open). Transient — retry with backoff; heavy /verify traffic can starve settlement.") };
        };
      };
      // H-2: Resolve token to verify nonce is bound to the correct network+token
      let resolvedToken = resolveTokenForNonce(signature.network);

      // Amount + replay model, two paths:
      //  • Server-nonce (ICP + legacy clients echo the ic402 nonce): lock it for the bound amount,
      //    and reject a nonce whose amount != the resource's advertised price (cross-resource).
      //  • Stock x402 (EVM): a conformant client sends NO server nonce. The amount is the
      //    resource's advertised price, enforced as exact-equality below; replay protection is the
      //    EIP-3009 authorization.nonce + the on-chain single-use transferWithAuthorization. ICP
      //    has no on-chain nonce, so it always requires the server nonce.
      let usesServerNonce = signature.nonce.size() > 0;
      let amount = if (usesServerNonce) {
        switch (nonceManager.lock(signature.nonce, signature.network, resolvedToken)) {
          case (null) {
            // 2.20.0: a locked nonce means a settlement with it is in flight, or ended with an
            // unknown outcome. Telling that caller to pay again with a fresh nonce could charge twice.
            if (nonceManager.isLocked(signature.nonce)) {
              // 2.21.0: a pending ICP charge made through settleFrom with setLedgerDedup on kept its
              // transfer; only the payer, calling settleFrom again, can have it re-sent.
              if (payerIsCaller) {
                switch (nonceManager.takePending(signature.nonce)) {
                  case (?p) { return await* resolvePendingCharge(signature, expectedAmount, p) };
                  case (null) {};
                };
              };
              // 2.22.0: in flight is not "funds may have moved". Nonces are predictable and not bound
              // to a payer, so the attempt holding the lock may be anyone's (an HTTP settle naming
              // any sender, or another principal's settleFrom); until it returns, answer "busy" —
              // unless that attempt names this same payer: it may be moving this payer's funds right
              // now (a client's re-send after a timeout), so that is pending, as before 2.22.0.
              if (not nonceManager.outcomeIsUnknown(signature.nonce) and not nonceManager.heldBy(signature.nonce, chargePayerKey(signature))) {
                return #policyDenied("A settlement with this payment is already in progress — retry this same payment in a few seconds; do not pay with a new nonce.");
              };
              return #settlementPending("A settlement with this payment is in flight, or its outcome is unknown — do NOT pay again. Wait for the first attempt's result; if it was #settlementPending, check the ledger before paying anew.");
            };
            return #expired("Server nonce expired, already used, or bound to a different network/token — nonces are single-use and expire (default 5 min). Re-request the resource to get a fresh 402 challenge and pay with its nonce.");
          };
          case (?a) {
            nonceManager.setHolder(signature.nonce, chargePayerKey(signature)); // 2.22.0
            switch (expectedAmount) {
              case (?e) {
                if (a != e) {
                  nonceManager.unlock(signature.nonce);
                  return #policyDenied("Nonce-bound amount " # Nat.toText(a) # " does not match the resource price " # Nat.toText(e));
                };
              };
              case (null) {};
            };
            a;
          };
        };
      } else {
        switch (expectedAmount, isEvmNetwork(signature.network)) {
          case (?e, true) { e }; // stock EVM client: amount comes from the resource, value==amount below
          case (_, false) { return #expired("ICP settlement requires the ic402 server nonce — echo the ic402Nonce from the 402 challenge's extra field in your payment; ICP has no on-chain replay protection without it.") };
          case (null, _) { return #expired("Cannot settle: no server nonce and no expected amount. Consumer canisters must pass expectedAmount (the advertised price) to settle(); clients may alternatively echo the challenge's ic402Nonce.") };
        };
      };

      // Dispatch to EVM settlement via EIP-3009 if eip155:* network
      if (isEvmNetwork(signature.network)) {
        let authz = switch (signature.authorization) {
          case (?a) { a };
          case (null) {
            nonceManager.unlock(signature.nonce);
            return #invalidSignature("EIP-3009 authorization required for EVM payments");
          };
        };

        // 2.22.0: refuse fields the chain could not hold instead of encoding them truncated.
        let fromBytes = EvmUtils.hexToBytes(authz.from);
        let authNonceBytes = Blob.toArray(authz.nonce);
        if (not EvmUtils.eip3009FieldsFit(authz.value, authz.validAfter, authz.validBefore, authNonceBytes)) {
          nonceManager.unlock(signature.nonce);
          return #invalidSignature("EIP-3009 authorization fields out of range: value, validAfter and validBefore must fit uint256 and the nonce must be 32 bytes");
        };
        // M-4: Validate EIP-3009 time window before any further processing. 2.22.0: validBefore is
        // strict, as on chain (see verifyPayment).
        let nowSeconds = Int.abs(Time.now() / 1_000_000_000);
        if (nowSeconds < authz.validAfter) { nonceManager.unlock(signature.nonce); return #expired("Authorization not yet valid") };
        // 2.23.1: and it must stay valid long enough to land (EvmSender.MIN_VALIDITY_SECONDS).
        if (EvmSender.expiresTooSoon(authz.validBefore, nowSeconds)) { nonceManager.unlock(signature.nonce); return #expired(EvmSender.EXPIRES_TOO_SOON) };

        // M-1: Derive deterministic Principal from EVM sender for policy tracking.
        // M-2: Uses 29 bytes of SHA-256 (232 bits) — collision probability ~2^-116.
        // Two EVM addresses mapping to the same Principal would share policy buckets.
        // This is acceptable for policy tracking (not for authentication).
        // 2.22.0 (E9): from the decoded address, so every hex-case spelling is one payer.
        let evmSender = evmPolicyPrincipal(authz.from);
        // I6: READ-ONLY here — a blocked/at-limit sender is still refused before the ecRecover
        // below, but the rate hit is recorded only on #confirmed (`from` is only claimed until
        // the signature verifies, so recording here let anyone spend a payer's budget).
        switch (policy.precheckCharge(evmSender, amount)) {
          case (#denied(r)) { nonceManager.unlock(signature.nonce); return #policyDenied(r) };
          case (#ok) {};
        };

        // Validate authorization parameters
        let canisterEvmAddr = switch (evmRecipient) {
          case (?addr) { addr };
          case (null) { nonceManager.unlock(signature.nonce); return #settlementFailed("Canister EVM address not derived yet — tECDSA derivation is async. Ensure startTimers() was called (or call deriveEvmRecipient), poll isEvmReady() until true, and check logs for 'EVM address derivation failed'. Transient at startup; retry after derivation.") };
        };
        // C-1 (v2): The EIP-3009 recipient MUST be the canister's own EVM address.
        // Without this check a payer can sign a self-transfer (to = an address they
        // control), pass signature verification, have the canister pay gas to
        // broadcast it, and still receive a valid receipt + access grant while the
        // merchant receives nothing. This is the core EVM payment-bypass fix.
        // 2.24.0: settleToSplit checks its split instead, below, once the chain and token are known.
        if (split == null and not EvmUtils.addressesEqual(authz.to, canisterEvmAddr)) {
          nonceManager.unlock(signature.nonce);
          return #invalidSignature("EIP-3009 recipient (to) must be the canister's EVM address (" # canisterEvmAddr # ")");
        };
        // v2 §6.1.2: the exact-EVM scheme requires the authorization value to EQUAL the amount
        // (not merely cover it). A v1 `>=` would accept an overpayment a strict v2 facilitator
        // rejects. unlock() is a no-op when there is no server nonce (stock EVM client).
        if (authz.value != amount) {
          nonceManager.unlock(signature.nonce);
          return #invalidSignature("invalid_exact_evm_payload_authorization_value_mismatch: value " # Nat.toText(authz.value) # " != required " # Nat.toText(amount));
        };

        // Verify EIP-712 signature locally
        let chainId = switch (extractChainId(signature.network)) {
          case (?id) { id };
          case (null) { nonceManager.unlock(signature.nonce); return #networkNotSupported("Invalid network: " # signature.network) };
        };
        // Multi-token: verify + settle against the token the payer actually signed for
        // (signature.asset), resolved via resolveEvmDomain so the verifyingContract, EIP-712 domain,
        // AND the on-chain execution token below all key off the SAME asset — not tokens[0]. A
        // legacy client that sends no asset falls back to the chain's first configured token. The
        // asset is cryptographically bound to the signature (it IS the verifyingContract), so a
        // spoofed asset simply fails verification.
        let chain = switch (findEvmChain(chainId)) {
          case (?c) { c };
          case (null) {
            nonceManager.unlock(signature.nonce);
            return #networkNotSupported("No EVM chain config for chainId " # Nat.toText(chainId));
          };
        };
        let tokenAddr = resolveEvmAsset(chain, signature.asset);
        let (tokenName, tokenVersion) = switch (resolveEvmDomain(chain, tokenAddr)) {
          case (?d) { (d.name, d.version) };
          case (null) {
            nonceManager.unlock(signature.nonce);
            return #invalidSignature("Unsupported asset " # tokenAddr # " on chain " # Nat.toText(chainId));
          };
        };
        // 2.24.0 (settleToSplit): the recipient must be exactly the split of (finder, this
        // canister, share), with the payee allowed by the operator's ceiling (EvmSplits.splitPayTo).
        // `splitRecipient` keeps the computed address (lowercase, 0x) for the receipt.
        var splitRecipient : ?Text = null;
        switch (split) {
          case (null) {};
          case (?sp) {
            switch (EvmSplits.splitPayTo(chainId, sp.finder, canisterEvmAddr, sp.finderShareBps, tokenAddr, evmSplitCeilingBps)) {
              case (#err(e)) { nonceManager.unlock(signature.nonce); return #policyDenied(e) };
              case (#ok(splitAddr)) {
                if (not EvmUtils.addressesEqual(authz.to, splitAddr)) {
                  nonceManager.unlock(signature.nonce);
                  return #invalidSignature("EIP-3009 recipient (to) must be the split " # splitAddr # " paying finder " # sp.finder # " " # Nat.toText(sp.finderShareBps) # " basis points and this canister (" # canisterEvmAddr # ") the rest");
                };
                splitRecipient := ?splitAddr;
              };
            };
          };
        };
        let verified = Eip712.verifyAuthorization(
          chainId,
          EvmUtils.hexToBytes(tokenAddr),
          fromBytes,
          EvmUtils.hexToBytes(authz.to),
          authz.value,
          authz.validAfter,
          authz.validBefore,
          authNonceBytes,
          authz.v,
          Blob.toArray(authz.r),
          Blob.toArray(authz.s),
          tokenName,
          tokenVersion,
        );
        if (not verified) {
          nonceManager.unlock(signature.nonce);
          return #invalidSignature("EIP-3009 authorization signature verification failed — the signature is not in the form USDC accepts on chain (low s, v of 27/28), or the recovered signer does not match authorization.from. Check the EIP-712 domain matches this canister's config (token name/version, chainId, verifyingContract = the paid asset) and that the signer key controls the from address. Not retryable without re-signing.");
        };

        // Execute transferWithAuthorization on-chain (canister acts as facilitator)
        let sender = switch (evmSenderInst) {
          case (?s) { s };
          case (null) { nonceManager.unlock(signature.nonce); return #settlementFailed("EVM sender not configured") };
        };

        // 2.22.0 (E5): never broadcast one authorization twice — a second broadcast can only
        // revert, at the canister's gas, holding the send lock. Claimed here, synchronously with
        // every check above, so two concurrent settles of it cannot both send. Pending, not failed:
        // the earlier broadcast may have paid.
        let authKey = sender.broadcastAuthorizations.key(chainId, tokenAddr, fromBytes, authNonceBytes);
        switch (sender.broadcastAuthorizations.claim(authKey, authz.validBefore, nowSeconds)) {
          case (#seen(prior)) {
            // 2.22.0: this call's server nonce, if any, was locked by this call and nothing of it
            // moved, so it is unlocked. Marking it "outcome unknown" let anyone replay one of his
            // own broadcast authorizations with a victim's fresh nonce and leave it pending. (A
            // retry with the broadcast's own nonce never gets here: that nonce is still locked.)
            nonceManager.unlock(signature.nonce);
            return #settlementPending(EvmSender.alreadyBroadcastText(prior));
          };
          case (#ok) {};
        };

        // 2.23.1: one inbound transfer in flight per payer (chain, token, from) — see
        // EvmSender.PayerGuard. Without it, authorizations from a wallet funded once would all pass
        // the simulation before signing while the first is unconfirmed. Claimed after the signature
        // verified, synchronously with the checks above; released however this settle returns.
        // Refused while that payer cools down after a sent transfer reverted, or is held while one
        // had not confirmed (PayerGuard.coolDown).
        let payerKey = sender.inFlightPayers.key(chainId, tokenAddr, fromBytes);
        switch (sender.inFlightPayers.claim(payerKey, nowSeconds)) {
          case (#ok) {};
          case (refused) {
            sender.broadcastAuthorizations.release(authKey); // not sent, so it may be sent later
            nonceManager.unlock(signature.nonce);
            return #policyDenied(switch (refused) { case (#coolingDown(until)) { EvmSender.payerCoolingText(until) }; case (_) { EvmSender.PAYER_BUSY } });
          };
        };
        try {
          // H-4 (v2): Reserve the daily spend synchronously BEFORE the value-moving
          // await (this whole prefix runs atomically up to the await, so concurrent
          // charges can no longer each pass a stale daily-limit check). Released on
          // any settlement failure below — releasing against `evmSpendDay` (captured
          // now) so a rollback after the await targets the same bucket across midnight.
          let evmSpendDay = policy.currentDay();
          policy.recordSpend(evmSender, amount);

          // 2.22.0: each await below is in `try`. Untried, a reject left the nonce locked as if in
          // flight ("busy" for a day), the authorization claimed and the daily reservation held.
          let execResult = try {
            await sender.executeTransferWithAuthorization(
              chainId, tokenAddr,
              fromBytes,
              EvmUtils.hexToBytes(authz.to),
              authz.value, authz.validAfter, authz.validBefore,
              authNonceBytes,
              authz.v, Blob.toArray(authz.r), Blob.toArray(authz.s),
            );
          } catch (e) {
            // The send may or may not have broadcast: keep the authorization claimed (never send it
            // twice) and the nonce locked, now with an unknown outcome. 2.23.1: hold the payer while
            // it may still land (PayerGuard.coolDown).
            sender.inFlightPayers.coolDown(payerKey, Int.abs(Time.now() / 1_000_000_000), EvmSender.UNCONFIRMED_HOLD_SECONDS);
            policy.releaseDaily(evmSender, evmSpendDay, amount);
            nonceManager.markOutcomeUnknown(signature.nonce);
            return #settlementPending("EIP-3009 broadcast call rejected (" # debug_show (Error.code(e)) # "): the transfer may or may not have been broadcast — NOT final: do not deliver value. Do not re-sign or pay again until the token's authorizationState for payer " # authz.from # " shows the authorization unused. " # Error.message(e));
          };

          // Extract the broadcast tx hash. #maybeSent (ambiguous broadcast — post-dispatch error /
          // inconsistent RPC / nonce-too-high) carries a hash and MAY still mine, so route it into the
          // SAME confirm-poll instead of discarding it as a hash-less #settlementFailed (G5/G6). No
          // double-pay: the EIP-3009 token nonce is single-use on-chain, so if the tx already mined it
          // yields a receipt below, else it parks as #settlementPending WITH the hash (recoverable).
          let txHash = switch (execResult) {
            case (#err(msg)) {
              sender.broadcastAuthorizations.release(authKey); // nothing was broadcast
              nonceManager.unlock(signature.nonce);
              policy.releaseDaily(evmSender, evmSpendDay, amount);
              return #settlementFailed("EIP-3009 execution failed: " # msg);
            };
            case (#ok(h)) { h };
            case (#maybeSent(m)) { m.txHash };
          };
          sender.broadcastAuthorizations.noteTx(authKey, txHash);
          // H-1 (v2): Mempool acceptance is NOT settlement finality. Confirm the transfer actually
          // mined (status == 1) before issuing a receipt; an on-chain revert (insufficient balance,
          // reused token nonce, paused token) must not yield a "paid" receipt.
          // A rejected confirm call is "confirmation unavailable" (#err): the tx was broadcast.
          let confirmation = try { await sender.confirmTransaction(chainId, txHash, 4) } catch (e) {
            #err(Error.message(e));
          };
          switch (confirmation) {
            case (#confirmed) {
              nonceManager.consumeLocked(signature.nonce);
              policy.recordRateHit(evmSender); // I6: the settle succeeded — now it counts
              let receipt : Types.PaymentReceipt = {
                id = nextReceiptId();
                amount;
                token = tokenAddr;
                sender = authz.from;
                recipient = switch (splitRecipient) { case (null) { canisterEvmAddr }; case (?a) { a } }; // 2.24.0: the split
                network = signature.network;
                timestamp = Time.now();
                txHash = ?txHash;
                sessionId = null;
                refunded = null;
              };
              return #ok(receipt);
            };
            case (#reverted) {
              // 2.23.1: it passed the simulation and reverted on chain — hold the payer now, and
              // cool it down for the hour below unless another transaction executed the
              // authorization (#used) (PayerGuard.coolDown).
              sender.inFlightPayers.coolDown(payerKey, Int.abs(Time.now() / 1_000_000_000), EvmSender.UNCONFIRMED_HOLD_SECONDS);
              policy.releaseDaily(evmSender, evmSpendDay, amount);
              // 2.22.0 (E7): THIS tx reverting does not mean no funds moved. transferWithAuthorization
              // can be submitted by anyone, so an earlier attempt or a mempool copier may have
              // executed the same authorization first — and then ours reverts. Ask the token.
              // A rejected check is "could not be checked" (#unknown); the reservation is released.
              let authState = try { await sender.authorizationState(chainId, tokenAddr, fromBytes, authNonceBytes) } catch (e) {
                #unknown(Error.message(e));
              };
              switch (authState) {
                case (#unused) {
                  sender.inFlightPayers.coolDown(payerKey, Int.abs(Time.now() / 1_000_000_000), EvmSender.REVERT_COOLDOWN_SECONDS);
                  nonceManager.unlock(signature.nonce);
                  return #settlementFailed("EIP-3009 transfer reverted on-chain (tx " # txHash # ") and the authorization is still unused on chain — no funds moved and no receipt issued. Usual causes: payer USDC balance below value, or token paused. Payments from this payer are refused for an hour. Fix the cause and re-sign a fresh authorization.");
                };
                case (#used) {
                  nonceManager.markOutcomeUnknown(signature.nonce); // no longer in flight
                  return #settlementPending("EIP-3009 transfer tx " # txHash # " reverted, but the authorization is already used on chain: another transaction executed it (an earlier attempt, or anyone who copied it — transferWithAuthorization can be submitted by anyone), or the payer cancelled it. Funds may have arrived. No receipt is issued. Payments from this payer are refused for 5 minutes. Do NOT re-sign or pay again — check the chain for payer " # authz.from # "'s authorization before taking a new payment.");
                };
                case (#unknown(e)) {
                  sender.inFlightPayers.coolDown(payerKey, Int.abs(Time.now() / 1_000_000_000), EvmSender.REVERT_COOLDOWN_SECONDS);
                  nonceManager.markOutcomeUnknown(signature.nonce); // no longer in flight
                  return #settlementPending("EIP-3009 transfer tx " # txHash # " reverted, and whether another transaction executed the authorization could not be checked (" # e # "). Funds may have arrived. No receipt is issued. Payments from this payer are refused for an hour. Do NOT re-sign or pay again until the token's authorizationState for payer " # authz.from # " shows the authorization unused.");
                };
              };
            };
            case (#pending) {
              // Keep the nonce locked (only the nonce clean-up removes it) so the same challenge is
              // not re-broadcast; release the daily reservation since no receipt
              // is issued. Caller MUST NOT deliver value on #settlementPending.
              // 2.23.1: hold the payer while it may still land or revert (PayerGuard.coolDown).
              sender.inFlightPayers.coolDown(payerKey, Int.abs(Time.now() / 1_000_000_000), EvmSender.UNCONFIRMED_HOLD_SECONDS);
              policy.releaseDaily(evmSender, evmSpendDay, amount);
              nonceManager.markOutcomeUnknown(signature.nonce); // 2.22.0: no longer in flight
              return #settlementPending("EIP-3009 transfer broadcast but not yet confirmed (tx " # txHash # ") — NOT final: do not deliver value. Re-poll confirmEvmTransaction with this tx hash; the tx may still mine. Do not re-submit the same authorization (it is single-use on-chain). Payments from this payer are refused for 5 minutes meanwhile.");
            };
            case (#err(e)) {
              sender.inFlightPayers.coolDown(payerKey, Int.abs(Time.now() / 1_000_000_000), EvmSender.UNCONFIRMED_HOLD_SECONDS); // 2.23.1
              policy.releaseDaily(evmSender, evmSpendDay, amount);
              nonceManager.markOutcomeUnknown(signature.nonce); // 2.22.0: no longer in flight
              return #settlementPending("EIP-3009 transfer broadcast; confirmation unavailable: " # e # " (tx " # txHash # ") — NOT final: do not deliver value. Transient RPC failure; re-poll confirmEvmTransaction with this tx hash rather than re-sending. Payments from this payer are refused for 5 minutes meanwhile.");
            };
          };
        } finally {
          sender.inFlightPayers.release(payerKey);
        };
      };

      // ── ICP settlement via ICRC-2 ──

      let tokenConfig = switch (findLedger(signature.network)) {
        case (?tc) { tc };
        case (null) {
          switch (config.tokens.size()) {
            case (0) { nonceManager.unlock(signature.nonce); return #tokenNotAccepted("No accepted token configured for network " # signature.network) };
            case (_) { config.tokens[0] };
          };
        };
      };

      if (signature.sender == "" or signature.sender.size() < 5) {
        nonceManager.unlock(signature.nonce);
        return #invalidSignature("Invalid sender principal: too short or empty");
      };
      // 2.22.0: Principal.fromText TRAPS on malformed text, and a trap is not caught by try/catch
      // (only rejects are), so a malformed sender over HTTP was a 5xx. Parse without trapping.
      let senderPrincipal = switch (Utils.principalFromText(signature.sender)) {
        case (?p) { p };
        case (null) {
          nonceManager.unlock(signature.nonce);
          return #invalidSignature("Invalid sender principal: " # signature.sender);
        };
      };
      // 2.21.1: the canister itself is never a payer. Its icrc2_transfer_from pulls `from` as the
      // spender, and DFINITY ledgers skip the allowance check when `from` is the caller's own
      // account, so a payment naming this canister would be paid out of its own funds — on the
      // HTTP path, where `sender` is only claimed, by anyone.
      if (Principal.equal(senderPrincipal, selfPrincipal)) {
        nonceManager.unlock(signature.nonce);
        return #invalidSignature("The paying principal cannot be this canister — name the principal whose allowance pays.");
      };

      // I6: `signature.sender` is only CLAIMED — the ledger's icrc2_transfer_from authenticates
      // it. Check read-only here and record the rate hit only on #Ok, so a settle that merely
      // names a principal (no allowance) never spends its per-minute budget (AUDIT I6).
      switch (policy.precheckCharge(senderPrincipal, amount)) {
        case (#denied(r)) { nonceManager.unlock(signature.nonce); return #policyDenied(r) };
        case (#ok) {};
      };

      let ledger : Types.LedgerActor = actor (Principal.toText(tokenConfig.ledger));

      // H-4 (v2): Reserve the daily spend synchronously before the transfer await
      // (closes the concurrent-charge daily-limit race); released on any failure
      // against `icpSpendDay` so a rollback after the await hits the same bucket.
      let icpSpendDay = policy.currentDay();
      policy.recordSpend(senderPrincipal, amount);

      // 2.21.0 (setLedgerDedup): send the fee, the nonce as memo and a created_at_time, so that a
      // re-submit can send this exact transfer again and the ledger's deduplication decides. The
      // fee is explicit because the ICP ledger's deduplication key holds the fee it charges: with
      // `fee = null`, a fee change between the attempts would make the re-send a NEW transfer.
      // Explicit, a changed fee is #BadFee, which both DFINITY ledgers check before deduplication.
      // Read once, so flipping the setting during the awaits cannot store a transfer sent without
      // deduplication fields.
      let dedup = ledgerDedup;
      let fee : ?Nat = if (not dedup) { null } else {
        try { ?(await ledger.icrc1_fee()) } catch (e) {
          // A fee query moves nothing, whatever its reject code.
          nonceManager.unlock(signature.nonce);
          policy.releaseDaily(senderPrincipal, icpSpendDay, amount);
          return #settlementFailed("Ledger fee query failed (nothing was charged; safe to retry): " # Error.message(e));
        };
      };
      let args : Types.TransferFromArg = {
        spender_subaccount = null;
        from = { owner = senderPrincipal; subaccount = null };
        to = recipientAccount();
        amount; // actual bound amount
        fee;
        memo = if (dedup) { ?signature.nonce } else { null };
        created_at_time = if (dedup) { ?Nat64.fromIntWrap(Time.now()) } else { null };
      };

      // 2.21.0: a settleFrom charge with dedup stores its transfer as in flight before the await,
      // so the nonce clean-up keeps the nonce even if it expires meanwhile, and a concurrent
      // re-submit cannot send it.
      if (dedup and payerIsCaller) {
        nonceManager.setInFlight(signature.nonce, { ledger = tokenConfig.ledger; network = signature.network; args });
      };
      try {
        let result = await ledger.icrc2_transfer_from(args);

        switch (result) {
          case (#Ok(blockIndex)) {
            chargeReceipt(signature, senderPrincipal, amount, tokenConfig.ledger, blockIndex);
          };
          case (#Err(err)) {
            nonceManager.unlock(signature.nonce);
            policy.releaseDaily(senderPrincipal, icpSpendDay, amount);
            switch (err) {
              case (#InsufficientFunds({ balance })) { #insufficientFunds("Insufficient funds: payer balance " # Nat.toText(balance) # " — the payer needs amount + the ledger transfer fee. Top up the payer account and retry.") };
              case (#InsufficientAllowance({ allowance })) { #insufficientFunds("Insufficient allowance: " # Nat.toText(allowance) # " — the payer must icrc2_approve this canister for at least amount + ledger fee before settle (the SDK's autoPayment does this; add a fee buffer). Re-approve and retry.") };
              case (_) { #settlementFailed("ICRC-2 error: " # debug_show(err)) };
            };
          };
        };
      } catch (e) {
        if (Utils.rejectedBeforeExecution(Error.code(e))) {
          // The ledger never ran the transfer (no such canister, overload, call never issued):
          // nothing was charged, so release the nonce and the daily reservation for a retry.
          nonceManager.unlock(signature.nonce);
          policy.releaseDaily(senderPrincipal, icpSpendDay, amount);
          return #settlementFailed("Ledger call failed before it ran (nothing was charged; safe to retry): " # Error.message(e));
        };
        // 2.20.0: any other reject leaves the outcome UNKNOWN — the transfer may have been
        // committed (see Utils.rejectedBeforeExecution). Before, this unlocked the nonce and
        // reported #settlementFailed, so re-submitting the same payment could charge the payer a
        // second time. Now the nonce stays locked (the same payment cannot be replayed), the daily
        // reservation stays held (2.22.0: settleFrom only, below), and no receipt is issued.
        nonceManager.markOutcomeUnknown(signature.nonce); // 2.22.0: no longer in flight
        // 2.22.0: over HTTP (`settle`) the sender is only claimed, so its reservation protected
        // nobody, and junk settles during a ledger outage could fill a victim's maxPerDay. Release
        // it there; a settleFrom charge keeps it (its re-submit issues the receipt against it).
        if (not payerIsCaller) { policy.releaseDaily(senderPrincipal, icpSpendDay, amount) };
        if (dedup and payerIsCaller) {
          // 2.21.0: make the stored transfer available, so the payer's settleFrom with this payment
          // can resolve it.
          nonceManager.setPending(signature.nonce, { ledger = tokenConfig.ledger; network = signature.network; args });
          return #settlementPending("Ledger call rejected (" # debug_show (Error.code(e)) # "): the transfer's outcome is UNKNOWN — it may have been charged. Do NOT deliver value and do NOT pay with a new nonce. Once the ledger is reachable, submit this SAME payment again (settleFrom, as the payer): the ledger's deduplication then settles it once, with a receipt either way. That works for the ledger's 24-hour window; after it, check the ledger instead. " # Error.message(e));
        };
        #settlementPending("Ledger call rejected (" # debug_show (Error.code(e)) # "): the transfer's outcome is UNKNOWN — it may have been charged. Do NOT deliver value and do NOT re-submit this payment. Check the payer's ledger history for a transfer to this canister's account before taking a new payment: " # Error.message(e));
      };
    };

    // Consume the nonce, count the payer's rate hit (I6: only a transfer that landed counts) and
    // issue the receipt of an ICP charge.
    func chargeReceipt(signature : Types.PaymentSignature, payer : Principal, amount : Nat, ledger : Principal, blockIndex : Nat) : Types.PaymentResult {
      nonceManager.consumeLocked(signature.nonce);
      policy.recordRateHit(payer);
      #ok({
        id = nextReceiptId();
        amount;
        token = Principal.toText(ledger);
        sender = signature.sender;
        recipient = recipientText();
        network = signature.network;
        timestamp = Time.now();
        txHash = ?Nat.toText(blockIndex);
        sessionId = null;
        refunded = null;
      });
    };

    // 2.21.0: re-send a pending ICP charge's exact transfer (setLedgerDedup); the ledger's
    // deduplication decides. #Ok: the first attempt had not landed and this one did. #Duplicate:
    // the first had landed. Both issue the receipt, against the daily reservation the first
    // attempt still holds. Anything else keeps the charge pending and the nonce locked; #TooOld
    // (the 24 h window passed) and #BadFee (the fee changed) also drop the stored transfer, since
    // re-sending it can no longer settle anything. The caller has checked the stored transfer out
    // (takePending marks it in flight), so a second re-submit arriving during the await sends
    // nothing, and the clean-up still keeps the nonce; every outcome below puts it back
    // (setPending), drops it (dropPending) or consumes the nonce (chargeReceipt).
    func resolvePendingCharge(signature : Types.PaymentSignature, expectedAmount : ?Nat, p : Nonce.PendingCharge) : async* Types.PaymentResult {
      let nonce = signature.nonce;
      // Only the payment that started the charge resolves it. The caller is authenticated as the
      // named sender (settleFrom); the nonce binds amount, network and token, not the payer, and the
      // re-sent transfer is the payer's own, so without this check another principal's settleFrom
      // with the same nonce would collect the receipt for the payer's money.
      let sameAmount = switch (expectedAmount) { case (?e) { e == p.args.amount }; case (null) { true } };
      if (signature.sender != Principal.toText(p.args.from.owner) or signature.network != p.network or not sameAmount) {
        nonceManager.setPending(nonce, p);
        return #settlementPending("A charge with this payment's nonce is pending, and this request does not match it (payer, network or amount) — nothing was sent. The payer resolves it by calling settleFrom with the original payment.");
      };
      let ledger : Types.LedgerActor = actor (Principal.toText(p.ledger));
      let result = try { await ledger.icrc2_transfer_from(p.args) } catch (e) {
        nonceManager.setPending(nonce, p);
        return #settlementPending("Re-sending the pending charge was rejected (" # debug_show (Error.code(e)) # "): still pending. Call settleFrom with this same payment later; do NOT pay with a new nonce. " # Error.message(e));
      };
      switch (result) {
        case (#Ok(blockIndex)) { chargeReceipt(signature, p.args.from.owner, p.args.amount, p.ledger, blockIndex) };
        case (#Err(#Duplicate({ duplicate_of }))) { chargeReceipt(signature, p.args.from.owner, p.args.amount, p.ledger, duplicate_of) };
        case (#Err(#TooOld)) {
          nonceManager.dropPending(nonce);
          #settlementPending("The pending charge is past the ledger's 24-hour deduplication window, so re-submitting can no longer settle it. Check the payer's ledger history for a transfer to this canister's account with this payment's nonce as memo before taking a new payment.");
        };
        case (#Err(#BadFee(_))) {
          nonceManager.dropPending(nonce);
          #settlementPending("The ledger's fee changed since the pending charge was sent, so re-submitting can no longer settle it. Check the payer's ledger history for a transfer to this canister's account with this payment's nonce as memo before taking a new payment.");
        };
        case (#Err(err)) {
          nonceManager.setPending(nonce, p);
          #settlementPending("Re-sending the pending charge returned " # debug_show (err) # ": still pending. Fix that and call settleFrom with this same payment again; do NOT pay with a new nonce.");
        };
      };
    };

    /// 2.17.0: `settle` for Candid endpoints (pass msg.caller). On the ICP rail `signature.sender`
    /// is only a claim — the payer's ICRC-2 allowance is the sole authentication — so the caller
    /// must BE the named sender (canonical text), checked before the nonce lock or any ledger call
    /// (#policyDenied otherwise). EVM: exactly `settle` (the EIP-3009 authorization is payer-signed).
    /// HTTP endpoints have no caller and keep `settle` (allowance-authenticated; 2.21.1: the
    /// canister itself is refused as the payer on both paths).
    public func settleFrom(caller : Principal, signature : Types.PaymentSignature, expectedAmount : ?Nat) : async Types.PaymentResult {
      if (not isEvmNetwork(signature.network) and signature.sender != Principal.toText(caller)) {
        return #policyDenied("Not authorized: this payment names sender " # signature.sender # " but was submitted by " # Principal.toText(caller) # " — on the ICP rail the caller must be the paying principal");
      };
      await* settleCore(signature, expectedAmount, not isEvmNetwork(signature.network), null);
    };

    // ── Session (delegates to Sessions module) ──

    /// Generate a session offer for a 402 response.
    /// TRAPS if intent.suggestedDeposit == 0 or intent.expiry <= Time.now() (expiry is in
    /// NANOSECONDS since epoch, like Time.now()) — validate client-influenced input first.
    public func offerSession(intent : Types.SessionIntent) : Types.SessionIntent {
      sessionsMgr.offerSession(intent);
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
    /// ICP (2.21.0): the ledger's fee is queried first; if that fails the open is refused with
    /// #settlementFailed and nothing moves. If the deposit call is then rejected with an unknown
    /// outcome, returns #err(#settlementPending(...)) and the session EXISTS, parked #closing with
    /// nothing consumed; the controller resolves it with reconcileSession.
    /// A per-caller open lock (auto-expiring after 5 min) rejects concurrent opens with
    /// #policyDenied.
    public func openSession(
      caller : Principal,
      intent : Types.SessionIntent,
      clientConfig : Types.SessionConfig,
      sig : Types.PaymentSignature,
    ) : async { #ok : Types.SessionState; #err : Types.PaymentResult } {
      await sessionsMgr.openSession(caller, intent, clientConfig, sig);
    };

    /// Verify a cumulative voucher and return the delta. Deprecated (2.17.0): prefer
    /// consumeVoucherFrom — see Sessions.consumeVoucher.
    public func consumeVoucher(voucher : Types.Voucher) : Types.VoucherResult {
      sessionsMgr.consumeVoucher(voucher);
    };

    /// 2.17.0: pass msg.caller; the session key's own principal skips the signature check (see Sessions).
    public func consumeVoucherFrom(caller : Principal, voucher : Types.Voucher) : Types.VoucherResult {
      sessionsMgr.consumeVoucherFrom(caller, voucher);
    };

    /// Get a session's public state.
    public func getSession(sessionId : Text) : ?Types.SessionState {
      sessionsMgr.getSession(sessionId);
    };

    /// H-1: Close a session — caller must be the session payer.
    public func closeSession(caller : Principal, sessionId : Text) : async Types.PaymentResult {
      let result = await sessionsMgr.closeSession(caller, sessionId);
      // Assign a proper receipt ID from the Gateway's counter
      switch (result) {
        case (#ok(receipt)) {
          // Re-stamp the id from the Gateway's counter; all other fund fields flow through.
          #ok({ receipt with id = nextReceiptId() });
        };
        case (other) { other };
      };
    };

    /// Force-close a session without auth (admin/timer use).
    /// WARNING: This method performs no access control. The consuming canister
    /// MUST restrict access (e.g., assert(Principal.isController(msg.caller)))
    /// before exposing this as a public method. Intended for timer callbacks
    /// and admin operations only.
    public func forceCloseSession(sessionId : Text) : async Types.PaymentResult {
      let result = await sessionsMgr.closeSessionInternal(sessionId);
      switch (result) {
        case (#ok(receipt)) {
          // Re-stamp the id from the Gateway's counter; all other fund fields flow through.
          #ok({ receipt with id = nextReceiptId() });
        };
        case (other) { other };
      };
    };

    /// Close all expired or idle sessions.
    public func closeExpiredSessions() : async [Types.PaymentResult] {
      await sessionsMgr.closeExpiredSessions();
    };

    /// M-8: Recover funds from an escrow subaccount.
    /// H-5: Always refunds to payer, caps at unconsumed amount. Accepts #closed only (2.17.3):
    /// #closing/#expired are refused while a close is in progress (recovery race).
    /// 2.22.0: pays only against the session's refundOwed entry and never more than it in total (see
    /// Sessions.recoverEscrow); `ledger` must be the session's own ledger (it is resolved from the
    /// session's token; any other is refused), so forwarding a caller-chosen ledger is harmless.
    /// ICP-ESCROW ONLY: refunds from the session's ICRC-1 escrow subaccount. EVM session
    /// deposits live in the canister's shared EVM pool and are NOT recoverable here — use
    /// reconcileSession / reconcileEvmDeposit (or an operator sweep) for EVM.
    public func recoverEscrow(
      caller : Principal,
      ledger : Types.LedgerActor,
      sessionId : Text,
      amount : Nat,
    ) : async { #ok : Nat; #err : Text } {
      await sessionsMgr.recoverEscrow(caller, ledger, sessionId, amount);
    };

    /// 2.23.0: recoverEscrow, reporting what moved instead of only the block index: the amount paid
    /// to the payer (the request after both caps), the ledger fee the recovery was accounted at (read
    /// just before the transfer), and the refund-owed entry left afterwards (Types.RecoveryReceipt).
    /// Same checks and caps as recoverEscrow.
    public func recoverEscrowReceipt(
      caller : Principal,
      ledger : Types.LedgerActor,
      sessionId : Text,
      amount : Nat,
    ) : async { #ok : Types.RecoveryReceipt; #err : Text } {
      await sessionsMgr.recoverEscrowReceipt(caller, ledger, sessionId, amount);
    };

    /// 1a: Send an ERC-20 transfer from the canister's EVM address via tECDSA, if EVM is
    /// configured. Returns the tx hash on mempool acceptance.
    ///
    /// ⚠️ UNCONFIRMED + DOUBLE-PAY FOOTGUN (G3): #ok is only a mempool ack, NOT settlement finality,
    /// and #maybeSent (ambiguous broadcast) is collapsed to #err here. This is the OUTBOUND rail —
    /// unlike the inbound EIP-3009 path it is NOT replay-protected on-chain, so an external caller
    /// that re-sends on #err after a #maybeSent that actually landed would DOUBLE-PAY. Callers MUST
    /// NOT finalize on #ok and MUST NOT re-broadcast on #err; use `sendErc20TransferConfirmed` (which
    /// parks #maybeSent as #pending) for any settle/refund path (B2). No in-repo caller uses this
    /// helper — it exists only for consumers that confirm independently.
    ///
    /// DEPRECATED (2.22.0): use `sendErc20TransferConfirmed`. Kept for compatibility; it may be
    /// removed in 3.0.0.
    ///
    /// No access control, no policy: it sends any amount from the canister's EVM address to any
    /// `to`, including funds that back open sessions. Gate it to the controller.
    public func sendErc20Transfer(chainId : Nat, token : Text, to : Text, amount : Nat) : async { #ok : Text; #err : Text } {
      switch (evmSenderInst) {
        case (?sender) {
          switch (await sender.sendErc20Transfer(chainId, token, to, amount)) {
            case (#ok(h)) { #ok(h) };
            case (#err(e)) { #err(e) };
            // 2.21.1: still collapsed to #err for API compatibility, but never as "safe to retry":
            // the text says MAYBE SENT and carries the hash to confirm (NonceTooLow and post-dispatch
            // RPC errors now land here too).
            case (#maybeSent(m)) { #err("MAYBE SENT — do NOT retry; confirm tx " # m.txHash # " first: " # m.reason) };
          };
        };
        case (null) { #err("EVM not configured (no ecdsaKeyName)") };
      };
    };

    /// Confirmed variant: broadcasts AND polls the receipt, returning a tri-state so the
    /// caller finalizes state ONLY on #confirmed. The marketplace settle/refund + EVM
    /// session-close paths use this so an unconfirmed/reverted transfer is never treated
    /// as settled (B2). See EvmSender.sendErc20TransferConfirmed.
    ///
    /// No access control, no policy: it sends any amount from the canister's EVM address to any
    /// `to`, including funds that back open sessions. Gate it to the controller (the example's
    /// `sweepEvm` does). Passing it to `ServiceRegistry.setEvmTransfer` does not expose it: the
    /// registry calls it only for its own payouts and refunds.
    public func sendErc20TransferConfirmed(chainId : Nat, token : Text, to : Text, amount : Nat) : async {
      #confirmed : Text;
      #reverted : Text;
      #pending : Text;
      #err : Text;
    } {
      switch (evmSenderInst) {
        case (?sender) { await sender.sendErc20TransferConfirmed(chainId, token, to, amount, 4) };
        case (null) { #err("EVM not configured (no ecdsaKeyName)") };
      };
    };

    /// SEC-0: cap the TOTAL EVM session deposit the canister will back per chain+token (the funded
    /// pool size). When set, openSession refuses to over-allocate the shared EVM address beyond it,
    /// so concurrent sessions can never reserve more than the canister can actually pay back. Set
    /// this to the USDC you have funded the canister's EVM address with; null = unbounded (legacy).
    public func setEvmPoolCap(cap : ?Nat) { evmEscrowMgr.setPoolCap(cap) };

    /// Read the configured EVM pool cap (see setEvmPoolCap). null = unbounded.
    public func getEvmPoolCap() : ?Nat { evmEscrowMgr.getPoolCap() };

    // Canonical advertised form: "0x" + 40 hex chars. Internal comparisons (addressesEqual /
    // hexToBytes) tolerate bare or 0X-prefixed hex, but 402 challenges carry the configured
    // string VERBATIM (requireEvm/describeAll), and strict x402 clients (viem isAddress)
    // reject non-canonical forms — so setEvmChains refuses them up front.
    func isCanonicalEvmAddress(a : Text) : Bool {
      Text.startsWith(a, #text "0x") and a.size() == 42 and EvmUtils.hexToBytes(a).size() == 20;
    };

    /// Replace the accepted EVM chain/token set at RUNTIME — repoint the EVM rail at a
    /// different chain (e.g. Base Sepolia ↔ Base mainnet), add or remove chains or tokens —
    /// without a redeploy. Takes effect immediately for NEW 402 challenges (`requireEvm`/
    /// `describeAll`/`supportedJson`), verify/settle chain resolution, AND session opens:
    /// Sessions holds its own captured copy of the chain list (Motoko records are value
    /// bindings), so this method updates BOTH cells in the same call — a Gateway-only swap
    /// would silently leave the session rail on the old chains.
    ///
    /// Already-OPEN sessions are unaffected and drain naturally: close/reconcile/park use
    /// session-stored fields (network/token/subaccount), never this list. In-flight MESSAGES
    /// complete on the chain set they resolved at entry (every money path resolves its chain
    /// into locals before its first await). A 402 challenge or session intent minted PRE-swap
    /// for a chain/token the swap removed fails CLEANLY at settle/open (nonce unlocked,
    /// nothing broadcast, no funds move) — the client re-requests a fresh challenge.
    ///
    /// TRANSIENT, like setPolicy/setAdmitRate/setRequireCallerBoundSessions: reverts to the
    /// constructor config on upgrade. Persist the choice in YOUR stable state and re-apply at
    /// init — a forgotten re-apply on a mainnet-flipped canister silently reverts it to the
    /// compiled-in chains (verify with getEvmChains after upgrades). No caller auth here:
    /// gate this behind your own controller check.
    ///
    /// 2.22.0: refuses a chain whose tokens have different decimals (checkEvmTokenDecimals — the
    /// constructor applies the same check and traps). Tokens listed on one chain must also be of
    /// EQUAL UNIT VALUE: the payer chooses which one to pay with.
    public func setEvmChains(chains : [Types.EvmChainConfig]) : { #ok; #err : Text } {
      // Validation is all-or-nothing: a rejected set leaves the live set untouched. Beyond
      // the constructor's (decimals-only) check, reject what would settle ambiguously or
      // brokenly; an empty list turns the EVM rail off, and zero-token chains are tolerated
      // and skipped by the advertising helpers, as at construction.
      switch (checkEvmTokenDecimals(chains)) {
        case (#err(e)) { return #err(e) };
        case (#ok) {};
      };
      var i = 0;
      for (chain in chains.values()) {
        if (chain.chainId == 0) {
          return #err("chainId must be nonzero (eip155:0 is not a network)");
        };
        // The RPC provider table is STATIC (EvmRpc.rpcServices): a chain it cannot serve
        // would still be advertised and mint nonces, then fail every broadcast — an
        // advertised-but-dead rail whose only symptom is client-side settle failures.
        if (EvmRpc.rpcServices(chain.chainId) == null) {
          return #err("chainId " # Nat.toText(chain.chainId) # " has no EVM-RPC provider mapping (see EvmRpc.rpcServices) — it would advertise 402 challenges that can never settle");
        };
        var j = 0;
        for (other in chains.values()) {
          if (j < i and other.chainId == chain.chainId) {
            return #err("duplicate chainId " # Nat.toText(chain.chainId) # " — chain lookups resolve the FIRST match, so later duplicates would be dead config");
          };
          j += 1;
        };
        if (chain.recipient != "" and not isCanonicalEvmAddress(chain.recipient)) {
          return #err("chain " # Nat.toText(chain.chainId) # ": recipient must be a 0x-prefixed 20-byte hex address (advertised verbatim in 402 challenges): " # chain.recipient);
        };
        var t = 0;
        for (tok in chain.tokens.values()) {
          if (not isCanonicalEvmAddress(tok.address)) {
            return #err("chain " # Nat.toText(chain.chainId) # ": token address must be a 0x-prefixed 20-byte hex address (advertised verbatim in 402 challenges): " # tok.address);
          };
          var u = 0;
          for (other in chain.tokens.values()) {
            if (u < t and EvmUtils.addressesEqual(other.address, tok.address)) {
              return #err("chain " # Nat.toText(chain.chainId) # ": duplicate token address " # tok.address # " — domain lookups resolve the first match, so the duplicate's EIP-712 domain would be dead config");
            };
            u += 1;
          };
          t += 1;
        };
        i += 1;
      };
      liveEvmChains := chains;
      sessionsMgr.setEvmChains(chains);
      #ok;
    };

    /// The EVM chain set currently in effect: the constructor config's until setEvmChains
    /// overrides it. Pair with setEvmChains to verify a flip (and after upgrades, to catch a
    /// forgotten re-apply).
    public func getEvmChains() : [Types.EvmChainConfig] { liveEvmChains };

    /// Total EVM deposit currently reserved by open sessions for a chain+token — read-only pool
    /// utilisation. Remaining headroom under a cap is getEvmPoolCap() − totalAllocated(chainId,
    /// token); an operator sizing the cap (or diagnosing "EVM pool over-allocation" rejections)
    /// reads it here instead of mirroring the escrow accounting.
    public func totalAllocated(chainId : Nat, token : Text) : Nat {
      evmEscrowMgr.totalAllocated(chainId, token);
    };

    /// Start recurring timers: close expired/idle sessions every 60s (then GC closed sessions
    /// older than 24h), and hourly GC of daily-spend, rate-limit, and revoked-grant state.
    /// Also one-shot: auto-initializes the HMAC seed from raw_rand (2.22.0: retried a few times
    /// on failure; grantsReady() says when it is set), and derives the canister's EVM address via
    /// tECDSA when config.ecdsaKeyName is set.
    /// Must be called from actor context (requires <system> capability). A consumer that does
    /// not call this must schedule closeExpiredSessions()/GC itself, or sessions never expire
    /// and rate-limit logs grow unbounded.
    ///
    /// CYCLES: the session sweep is SELF-ARMING (since 2.11.0) — it runs only while a session is
    /// not yet #closed and disarms itself at the first tick after the last one closes (closed
    /// records are kept 24h and deleted by a later sweep, 2.17.5), so an idle canister is left with just
    /// the hourly GC tick below. A recurring timer is billed per tick regardless of what the
    /// callback does, which made the old always-on 60s sweep the largest fixed cost of embedding
    /// ic402 in a many-small-canisters topology. Confirm with sessionExpiryTimerArmed().
    ///
    /// Same as `startTimersWith({ hourlyGc = true })`.
    public func startTimers<system>() { startTimersWith<system>({ hourlyGc = true }) };

    /// startTimers, with the hourly clean-up optional (2.19.0). With `hourlyGc = false` it arms
    /// the session sweep and the two install one-shots (HMAC seed, EVM address derivation) but not
    /// the hourly recurring timer, which costs a wake (~28M cycles) every hour whatever it finds.
    /// The host then MUST call runMaintenance() itself: see the Gateway header for why and how
    /// often.
    public func startTimersWith<system>(opts : { hourlyGc : Bool }) {
      // Close expired sessions every 60 seconds, then GC stale entries. Armed unconditionally:
      // on upgrade a `persistent actor` re-runs its init body (where this call lives) BEFORE
      // postupgrade restores stable sessions, so gating the arm on "are there sessions?" would
      // leave exactly the canisters that DO have live sessions unswept. The first tick disarms
      // if there is nothing to do — at most one wasted tick per install/upgrade.
      sessionsMgr.armExpiryTimer<system>();
      // Garbage-collect stale policy data and revoked grants every hour
      if (opts.hourlyGc) {
        maintenanceTimer := ?Timer.recurringTimer<system>(#seconds 3600, func() : async () {
          policy.gcDailySpend();
          // SEC-1: rateLimitLog is keyed on attacker-chosen principals (every session-open
          // attempt records the caller; settles record only on success, I6), so it can grow
          // unbounded without this GC. gcRateLimit was written for exactly this attack.
          policy.gcRateLimit();
          grants.gcRevokedGrants();
        });
      };

      // Auto-init HMAC seed from randomness on first deployment
      seedGrants<system>(0);

      // Auto-derive EVM address from tECDSA key if configured
      switch (config.ecdsaKeyName) {
        case (?keyName) {
          ignore Timer.setTimer<system>(#seconds 0, func() : async () {
            // 2.18.1: inline — was two self-calls (deriveEvmRecipient, deriveRecipient) before the
            // management call, each holding a reply reservation during install/upgrade.
            await* deriveCurrent(keyName);
          });
        };
        case (null) {};
      };
    };

    // The grant HMAC seed, from raw_rand in a one-shot timer. 2.22.0: a failed raw_rand is retried
    // (5 more one-shots, 5 s to 80 s apart, about 2.5 minutes in all), since issueGrant traps until
    // seeded (grantsReady). Already seeded (restored by loadStable on upgrade): no call at all.
    func seedGrants<system>(attempt : Nat) {
      let delay = if (attempt == 0) { 0 } else { 5 * 2 ** (attempt - 1 : Nat) };
      ignore Timer.setTimer<system>(#seconds delay, func() : async () {
        if (grants.grantsReady()) return;
        let ic : actor { raw_rand : () -> async Blob } = actor "aaaaa-aa";
        try { ignore grants.initHmacSeed(await ic.raw_rand()) } catch (_) {
          if (attempt < 5) { seedGrants<system>(attempt + 1) };
        };
      });
    };

    /// Whether startTimers armed the hourly clean-up (false after startTimersWith({ hourlyGc =
    /// false }), and before any start). Timers do not survive an upgrade; the init body re-arms.
    public func maintenanceTimerArmed() : Bool { maintenanceTimer != null };

    /// The hourly clean-up, run by the host instead (2.19.0): drops daily-spend entries from
    /// earlier days, rate-limit entries with no hit in the last 60 s, and revoked grants older
    /// than 7 days. Synchronous, with no trap path. Removes at most 10,000 entries per map per
    /// call; `more` is true when that cap stopped it, so call again in a later message. The cap
    /// bounds removals, not the scan: a call can walk each whole map, so its instruction cost
    /// grows with the maps, like the hourly timer's. Run it often enough to keep them small.
    /// Required at least daily after startTimersWith({ hourlyGc = false }): see the Gateway header.
    public func runMaintenance() : {
      dailySpendRemoved : Nat;
      rateLimitRemoved : Nat;
      revokedGrantsRemoved : Nat;
      more : Bool;
    } {
      let d = policy.gcDailySpendUpTo(maintenanceCapPerMap);
      let r = policy.gcRateLimitUpTo(maintenanceCapPerMap);
      let g = grants.gcRevokedGrantsUpTo(maintenanceCapPerMap);
      {
        dailySpendRemoved = d.removed;
        rateLimitRemoved = r.removed;
        revokedGrantsRemoved = g.removed;
        more = d.more or r.more or g.more;
      };
    };

    /// Whether the session-expiry sweep is currently armed. `false` on an idle canister is the
    /// expected steady state (nothing to expire ⇒ nothing ticking ⇒ no per-tick cycle burn);
    /// `true` while any session is not yet #closed (retained #closed records do not count since
    /// 2.17.5), and for up to one interval after that. Pair it with sessionCounts() to explain a
    /// canister's timer burn without guessing.
    public func sessionExpiryTimerArmed() : Bool { sessionsMgr.expiryTimerArmed() };

    /// Set the session-expiry sweep cadence in seconds (default 60), applied immediately.
    /// A session is closed within this interval of passing its maxDuration/idleTimeout, and until
    /// then holds its slice of maxConcurrentSessions and of the EVM pool cap — nothing about
    /// settlement correctness depends on the cadence, so this trades expiry latency (and held
    /// capacity) for cycles. Prefer leaving it at 60: with the self-arming sweep an idle canister
    /// already pays nothing, so raising it only helps canisters that hold sessions continuously.
    public func setSessionExpiryIntervalSeconds<system>(seconds : Nat) : { #ok; #err : Text } {
      sessionsMgr.setExpiryIntervalSeconds<system>(seconds);
    };

    /// Arm the session-expiry sweep (idempotent). startTimers already does this; call it directly
    /// only if you restore sessions into a Sessions instance you drive yourself.
    public func armSessionExpiryTimer<system>() { sessionsMgr.armExpiryTimer<system>() };

    // ── Policy ──

    /// Set spending policy: global (caller=null) or per-caller override.
    /// No access control: the consuming canister MUST restrict access
    /// (e.g., assert(Principal.isController(msg.caller))) before exposing it.
    public func setPolicy(caller : ?Principal, p : Types.SpendingPolicy) {
      switch (caller) {
        case (null) { policy.setGlobalPolicy(p) };
        case (?c) { policy.setCallerPolicy(c, p) };
      };
    };

    /// Remove a per-caller policy override, reverting the caller to the global policy — the
    /// write-path complement of setPolicy(?caller, _). Without it, the only way "back" from an
    /// override was overwriting it with a copy of the global policy (which then no longer tracks
    /// later global changes). Gate on the consumer's owner/controller check like setPolicy.
    public func removeCallerPolicy(caller : Principal) {
      policy.removeCallerPolicy(caller);
    };

    /// Get the effective spending policy for a caller.
    public func getPolicy(caller : Principal) : Types.SpendingPolicy {
      policy.getEffectivePolicy(caller);
    };

    /// Get the global (null-keyed) spending policy — the one set via setPolicy(null, _).
    /// Lets a canister expose its configured limits for read-back without naming a caller.
    public func getGlobalPolicy() : Types.SpendingPolicy {
      policy.getGlobalPolicy();
    };

    /// Get the current daily spend total for a caller.
    public func dailySpend(caller : Principal) : Nat {
      policy.getDailySpendAmount(caller);
    };

    /// Observability (NEW-4): session status counts (parked #closing sessions are the watch
    /// metric — a deposit whose close broadcast but hasn't confirmed).
    /// `refundOwed` (2.18.0) counts closed ICP sessions that left payer funds in escrow (a failed refund
    /// leg; also reconcileSession and, since 2.22.0, forceResolveSession) and that the payer has not yet
    /// emptied with recoverEscrow; their records are kept past the 24h GC until then (clearRefundOwed
    /// drops one whose escrow is in fact empty).
    public func sessionCounts() : {
      total : Nat; open : Nat; closing : Nat; closed : Nat; expired : Nat; refundOwed : Nat;
    } {
      sessionsMgr.sessionCounts();
    };

    /// 2.18.0: the owed refunds behind sessionCounts().refundOwed. Persist them in their OWN stable
    /// variable (they are not in toStable(), so StableGatewayState is unchanged) and restore them with
    /// loadRefundOwed after loadStable. 2.22.0: REQUIRED — recoverEscrow pays an ICP session only
    /// against its entry, so entries an upgrade drops leave those remainders with no in-band way out.
    public func refundOwedToStable() : [Types.RefundOwed] { sessionsMgr.refundOwedToStable() };

    /// Restore the owed refunds saved by refundOwedToStable (call after loadStable).
    public func loadRefundOwed(data : [Types.RefundOwed]) { sessionsMgr.loadRefundOwed(data) };

    /// 2.22.0: drop a session's owed-refund entry whose escrow is in fact empty (a refund reported as
    /// failed that had landed), so sessionCounts().refundOwed can return to 0. See
    /// Sessions.clearRefundOwed. Moves no funds. Controller-gate it at the consumer.
    public func clearRefundOwed(sessionId : Text) : { #ok; #err : Text } { sessionsMgr.clearRefundOwed(sessionId) };

    /// Opt-in (default OFF): require an ICP-rail session's Ed25519 voucher key to BE the caller's
    /// own IC identity key (self-authenticating principal check), so the session opener and its
    /// voucher signer are provably the same principal. Leave OFF unless every session client uses
    /// a raw Ed25519 identity — II delegations and secp256k1/P-256 callers would be rejected.
    /// ICP rail only (an EVM session's payer identity is the EVM address, not msg.caller).
    /// Transient: re-apply at init, like setPolicy/setEvmPoolCap.
    public func setRequireCallerBoundSessions(on : Bool) {
      sessionsMgr.setRequireCallerBoundSessions(on);
    };

    /// 2.17.0 (default ON): see Sessions.setSignedVoucherFallback. Transient: re-apply at init.
    public func setSignedVoucherFallback(on : Bool) { sessionsMgr.setSignedVoucherFallback(on) };

    /// 2.21.0 (default OFF): resolve a pending ICP charge through the ledger's deduplication.
    ///
    /// Turn it on ONLY if every ledger in `Config.tokens` deduplicates `icrc2_transfer_from` on
    /// `created_at_time` + `memo`, as DFINITY's ICP and ICRC-1 ledgers do. ICRC-1 makes
    /// deduplication a SHOULD, and nothing a ledger exposes declares it, so this is the operator's
    /// declaration. On a ledger that does not deduplicate, a re-submitted pending payment is
    /// charged twice.
    ///
    /// With it on, every ICP charge queries `icrc1_fee` first and sends that fee, the payment nonce
    /// as memo and a `created_at_time`. A fee query that fails moves nothing, so a stopped ledger
    /// refuses the charge cleanly (#settlementFailed, nonce unlocked) instead of leaving it pending.
    ///
    /// A charge made through `settleFrom` (the caller is the payer) whose transfer is then rejected
    /// with an unknown outcome keeps that transfer. The payer calls `settleFrom` again with the SAME
    /// payment, and the identical transfer is sent again: the ledger answers #Ok (the first had not
    /// landed; this one did) or #Duplicate (the first had), and either way the payer gets one
    /// receipt. Through `settle` (HTTP: `sender` is only claimed, and nonces are not secret) nothing
    /// is stored and nothing is resolved, so nobody can collect the receipt for another payer's
    /// transfer; those charges stay #settlementPending as in 2.20.0. The nonce and its stored
    /// transfer are kept for the ledger's 24-hour window (the nonce clean-up skips them). After
    /// that, after #TooOld or #BadFee, or after an upgrade (the stored transfer is transient), the
    /// charge stays #settlementPending as in 2.20.0. The ledger's memo limit must be at least 32
    /// bytes (both DFINITY ledgers allow 32); a shorter limit traps every charge. Transient:
    /// re-apply at init.
    public func setLedgerDedup(on : Bool) { ledgerDedup := on };

    /// 2.21.0: whether setLedgerDedup is on.
    public func ledgerDedupEnabled() : Bool { ledgerDedup };

    /// Whether a session's voucher key is the payer's own IC identity key (derived, works for
    /// pre-existing sessions). null = unknown session; false = "not identity-bound", never
    /// "invalid" — see Identity.selfAuthPrincipalOfEd25519 for the derivation and its limits.
    public func sessionCallerBound(sessionId : Text) : ?Bool {
      sessionsMgr.sessionCallerBound(sessionId);
    };

    /// Operator escape hatch: force a session stuck in #closing to a terminal state so it's
    /// GC-eligible (state assertion only — moves no funds). Controller-gate at the consumer.
    /// 2.22.0: refused while a close of the session is in flight; an ICP session forced records
    /// deposited − consumed as owed to the payer (see Sessions.forceResolveSession). For ICP, call
    /// reconcileSession first.
    public func forceResolveSession(sessionId : Text) : { #ok; #err : Text } {
      sessionsMgr.forceResolveSession(sessionId);
    };

    /// Read-only EVM tx confirmation (re-poll a receipt; NEVER broadcasts) — wired into the
    /// registry/sessions reconcile paths so a parked tx can be confirmed without re-sending it.
    public func confirmEvmTransaction(chainId : Nat, txHash : Text) : async { #confirmed; #reverted; #pending; #err : Text } {
      switch (evmSenderInst) {
        case (?sender) { await sender.confirmTransaction(chainId, txHash, 1) };
        case (null) { #err("EVM sender not configured") };
      };
    };

    /// Recovery: reconcile a session left in #closing (delegates to Sessions). EVM: confirm-only
    /// re-poll of the parked close tx. ICP (2.20.0): after a settle rejected with an unknown
    /// outcome, reads the escrow balance and reopens the session (nothing paid) or closes it with
    /// the remainder recoverable (paid). Moves no funds itself. Controller-gate it at the consumer.
    public func reconcileSession(sessionId : Text) : async { #ok : Text; #err : Text } {
      await sessionsMgr.reconcileSession(sessionId);
    };

    // ── M8: inbound EVM deposit drain + reconcile (delegates to Sessions; controller-gate at the consumer) ──

    /// Count of inbound EVM deposits broadcast but not yet confirmed/reconciled. Poll this after
    /// setEvmDrainMode(true) and upgrade only once it reaches 0 so no pending deposit is lost.
    public func pendingEvmDepositCount() : Nat { sessionsMgr.pendingEvmDepositCount() };

    /// List the tracked pending inbound EVM deposits (observability / manual recovery).
    public func listPendingEvmDeposits() : [{ txHash : Text; payer : Principal; payerEvmAddress : Text; chainId : Nat; token : Text; amount : Nat; createdAt : Int }] {
      sessionsMgr.listPendingEvmDeposits();
    };

    /// Set drain mode — when true, openSession rejects new inbound EVM deposits so the pending
    /// tracker can drain to 0 before an upgrade.
    public func setEvmDrainMode(on : Bool) { sessionsMgr.setDrainMode(on) };
    /// Read the current drain-mode flag (see setEvmDrainMode). Transient — false after upgrade.
    public func getEvmDrainMode() : Bool { sessionsMgr.getDrainMode() };

    /// Reconcile a tracked pending inbound deposit: poll the receipt, refund-on-confirm to the
    /// payer's EVM address (drop on revert, leave otherwise).
    public func reconcileEvmDeposit(txHash : Text) : async { #refunded : Text; #reverted; #stillPending; #notFound; #err : Text } {
      await sessionsMgr.reconcileEvmDeposit(txHash);
    };

    // ── Content Delivery (delegates to Grants module) ──

    /// Initialize HMAC seed from randomness. Call once on first deployment.
    /// Returns true if initialized, false if already set (idempotent).
    public func initHmacSeed(randomBlob : Blob) : Bool {
      grants.initHmacSeed(randomBlob);
    };

    /// 2.22.0: whether issueGrant can issue (the HMAC seed is set). startTimers seeds it from
    /// raw_rand shortly after install, retrying a failed call a few times; loadStable restores it.
    /// Check it BEFORE settling a payment you will answer with a grant: issueGrant traps while it
    /// is false, and a trap after the settle leaves the payer charged with nothing delivered.
    public func grantsReady() : Bool { grants.grantsReady() };

    /// Issue an access grant after successful payment. Traps before the HMAC seed is set
    /// (grantsReady) or for a content id containing '|' — check both before settling. A TTL above
    /// 7 days is capped to 7 days (2.22.0: revocations are kept that long).
    public func issueGrant(
      contentRef : Types.ContentRef,
      grantee : Principal,
      receiptId : Text,
      ttlNanos : Int,
    ) : Types.AccessGrant {
      grants.issueGrant(contentRef, grantee, receiptId, ttlNanos);
    };

    /// Verify an access grant (stateless HMAC check + expiry + revocation).
    /// H-8 (v2): `caller` must equal grant.grantee — grants are non-transferable.
    public func verifyGrant(caller : Principal, grant : Types.AccessGrant) : Types.AccessGrantResult {
      grants.verifyGrant(caller, grant);
    };

    /// Revoke a grant (e.g., after refund).
    public func revokeGrant(grantId : Text) : Bool {
      grants.revokeGrant(grantId);
    };

    // ── Stable state (composes sub-module states) ──

    /// Serialize all gateway state for stable storage (sessions, nonces, policy, grants,
    /// counters, EVM allocations). TRANSIENT recovery state is NOT serialized: parked
    /// close-tx hashes, the pending inbound EVM deposit tracker, drain mode, and the
    /// facilitator rate bucket. Before upgrading, drain in-flight EVM deposits:
    /// setEvmDrainMode(true), poll pendingEvmDepositCount() == 0, then upgrade — otherwise a
    /// pending deposit's only trace after upgrade is the tx hash in its #settlementPending error.
    public func toStable() : Types.StableGatewayState {
      {
        sessions = sessionsMgr.toStable();
        nonces = nonceManager.toStable();
        policy = policy.toStable();
        receiptCounter;
        accessGrants = ?grants.toStable();
        consumedTxHashes = null; // Deprecated: EIP-3009 nonces replace tx hash tracking
        // M-3: Persist session counter independently
        sessionCounter = ?sessionsMgr.getCounter();
        // Self-derived EVM address
        evmRecipient;
        // EVM session allocations
        evmAllocations = ?evmEscrowMgr.toStable();
      };
    };

    /// Restore all gateway state from stable storage. Call from postupgrade, AFTER checking
    /// Ic402.checkSchemaVersion(persisted) — a schema mismatch should branch to a migration,
    /// not decode blindly. An ICP session restored #closing is resolved with reconcileSession (it
    /// reads the escrow). An EVM one has no parked tx hash after an upgrade (transient): resolve it
    /// via forceResolveSession + out-of-band reconciliation.
    public func loadStable(data : Types.StableGatewayState) {
      nonceManager.loadStable(data.nonces);
      policy.loadStable(data.policy);
      receiptCounter := data.receiptCounter;

      // M-3: Restore session counter from dedicated field, fall back to receipt counter
      switch (data.sessionCounter) {
        case (?sc) { sessionsMgr.setCounter(sc) };
        case (null) { sessionsMgr.setCounter(receiptCounter) };
      };

      sessionsMgr.loadStable(data.sessions);

      switch (data.accessGrants) {
        case (?grantsData) {
          grants.loadStable(grantsData);
        };
        case (null) {};
      };

      // Restore self-derived EVM address
      switch (data.evmRecipient) {
        case (?addr) { evmRecipient := ?addr };
        case (null) {};
      };

      // consumedTxHashes ignored on load (deprecated — EIP-3009 nonces handle replay)

      // Restore EVM session allocations
      switch (data.evmAllocations) {
        case (?allocs) { evmEscrowMgr.loadStable(allocs) };
        case (null) {};
      };
    };
  };
};
