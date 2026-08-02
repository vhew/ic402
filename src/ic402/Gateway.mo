/// ic402 — Main gateway class. Orchestrates charges, sessions, grants, and policy.
import Types "Types";
import Policy "Policy";
import Nonce "Nonce";
import Escrow "Escrow";
import GrantsMod "Grants";
import SessionsMod "Sessions";
import Time "mo:base/Time";
import Nat "mo:base/Nat";
import Int "mo:base/Int";
import Text "mo:base/Text";
import Iter "mo:base/Iter";
import Buffer "mo:base/Buffer";
import Principal "mo:base/Principal";
import Timer "mo:base/Timer";
import Error "mo:base/Error";
import Nat32 "mo:base/Nat32";
import Blob "mo:base/Blob";
import Array "mo:base/Array";
import HashMap "mo:base/HashMap";
import SHA256 "mo:sha2/Sha256";
import Utils "Utils";
import EvmAddress "EvmAddress";
import EvmEscrow "EvmEscrow";
import EvmRpc "EvmRpc";
import EvmSender "EvmSender";
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
    for (tok in chain.tokens.vals()) {
      if (EvmUtils.addressesEqual(tok.address, tokenAddr)) return ?{ name = tok.name; version = tok.version };
    };
    null;
  };

  /// Main payment gateway. Orchestrates charges, sessions, grants, escrow, and policy.
  ///
  /// Consumer obligations:
  /// - `selfPrincipal` MUST be the consuming canister's own principal (bound into voucher
  ///   payloads and escrow subaccount derivation).
  /// - Call `startTimers<system>()` once from actor context, or schedule session expiry/GC
  ///   yourself.
  /// - Persist `toStable()` in preupgrade and restore with `loadStable()` in postupgrade;
  ///   check `Ic402.checkSchemaVersion` against your persisted version BEFORE loadStable.
  /// - EVM rails are unavailable until the async tECDSA address derivation completes —
  ///   poll `isEvmReady()`.
  public class Gateway(config : Types.Config, selfPrincipal : Principal) {

    let policy = Policy.Engine();
    let nonceManager = Nonce.NonceManager(selfPrincipal);
    let escrowManager = Escrow.EscrowManager(selfPrincipal);
    let grants = GrantsMod.Grants(selfPrincipal);
    let evmEscrowMgr = EvmEscrow.EvmEscrowManager();
    let evmSenderInst : ?EvmSender.EvmSender = switch (config.ecdsaKeyName) {
      case (?keyName) { ?EvmSender.EvmSender(keyName, config.evmRpcCanister) };
      case (null) { null };
    };

    var receiptCounter : Nat = 0;
    // Self-derived EVM address (from tECDSA key). Populated by deriveEvmRecipient().
    var evmRecipient : ?Text = null;
    // Live EVM chain set (see setEvmChains). Starts as the constructor config's evmChains;
    // every Gateway chain lookup (findEvmChain, requireEvm, describeAll, supportedJson) reads
    // THIS, never config.evmChains, so a runtime swap takes effect for new requests.
    var liveEvmChains : [Types.EvmChainConfig] = config.evmChains;

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

    let sessionsMgr = SessionsMod.Sessions(
      selfPrincipal, config, policy, escrowManager,
      evmEscrowMgr, evmSenderInst,
      { get = func() : ?Text { evmRecipient } },
    );
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
    public func deriveEvmRecipient(ecdsaKeyName : Text) : async () {
      switch (evmRecipient) {
        case (?_) { return }; // Already derived
        case (null) {};
      };
      let result = await management_canister.ecdsa_public_key({
        key_id = { name = ecdsaKeyName; curve = #secp256k1 };
        canister_id = null;
        derivation_path = [];
      });
      // H-2: Surface error instead of silently swallowing — operators can see this in canister logs
      switch (EvmAddress.fromCompressedPublicKey(Blob.toArray(result.public_key))) {
        case (#ok(addr)) { evmRecipient := ?addr };
        case (#err(msg)) {
          Debug.print("ic402 CRITICAL: EVM address derivation failed: " # msg # ". EVM payments will be unavailable.");
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
      for (chain in liveEvmChains.vals()) {
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
      for (chain in liveEvmChains.vals()) {
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
      for (chain in liveEvmChains.vals()) {
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
      for (chain in liveEvmChains.vals()) {
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
      let nowSeconds = Int.abs(Time.now() / 1_000_000_000);
      if (nowSeconds < authz.validAfter) {
        return { isValid = false; invalidReason = ?"invalid_exact_evm_payload_authorization_valid_after"; payer = ?authz.from };
      };
      if (nowSeconds > authz.validBefore) {
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
    /// #settlementPending, where the nonce stays LOCKED (GC'd at expiry) so the same challenge
    /// cannot be re-broadcast. #settlementPending is NOT final: no receipt is issued and the
    /// caller MUST NOT deliver value — the broadcast tx may still mine later (handle out-of-band).
    ///
    /// Multi-token (v2.5.0): the EVM verify + on-chain execution key off `signature.asset`
    /// (the EIP-712 verifyingContract the payer signed for); `asset = null` falls back to the
    /// chain's FIRST configured token. EVM additionally requires authorization.to == the
    /// canister's derived EVM address and authorization.value == the settled amount (exact).
    ///
    /// Interleaving: this method awaits (EVM broadcast + confirmation poll / ICP ledger call).
    /// The nonce lock and the daily-spend reservation commit synchronously BEFORE the first
    /// await and are rolled back on failure. EVM settles are metered by the GLOBAL facilitator
    /// token bucket and can return #policyDenied("Rate limited…") under load; ICP settles are not.
    public func settle(signature : Types.PaymentSignature, expectedAmount : ?Nat) : async Types.PaymentResult {
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
          case (null) { return #expired("Server nonce expired, already used, or bound to a different network/token — nonces are single-use and expire (default 5 min). Re-request the resource to get a fresh 402 challenge and pay with its nonce.") };
          case (?a) {
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

        // M-4: Validate EIP-3009 time window before any further processing
        let nowSeconds = Int.abs(Time.now() / 1_000_000_000);
        if (nowSeconds < authz.validAfter) { nonceManager.unlock(signature.nonce); return #expired("Authorization not yet valid") };
        if (nowSeconds > authz.validBefore) { nonceManager.unlock(signature.nonce); return #expired("Authorization expired") };

        // M-1: Derive deterministic Principal from EVM sender for policy tracking.
        // M-2: Uses 29 bytes of SHA-256 (232 bits) — collision probability ~2^-116.
        // Two EVM addresses mapping to the same Principal would share policy buckets.
        // This is acceptable for policy tracking (not for authentication).
        let evmSenderBytes = Blob.toArray(Text.encodeUtf8("evm:" # authz.from));
        let evmSenderHash = SHA256.fromArray(#sha256, evmSenderBytes);
        let hashArray = Blob.toArray(evmSenderHash);
        let evmSender = Principal.fromBlob(Blob.fromArray(Array.subArray(hashArray, 0, 29)));
        switch (policy.checkCharge(evmSender, amount)) {
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
        if (not EvmUtils.addressesEqual(authz.to, canisterEvmAddr)) {
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
        let verified = Eip712.verifyAuthorization(
          chainId,
          EvmUtils.hexToBytes(tokenAddr),
          EvmUtils.hexToBytes(authz.from),
          EvmUtils.hexToBytes(authz.to),
          authz.value,
          authz.validAfter,
          authz.validBefore,
          Blob.toArray(authz.nonce),
          authz.v,
          Blob.toArray(authz.r),
          Blob.toArray(authz.s),
          tokenName,
          tokenVersion,
        );
        if (not verified) {
          nonceManager.unlock(signature.nonce);
          return #invalidSignature("EIP-3009 authorization signature verification failed — the recovered signer does not match authorization.from. Check the EIP-712 domain matches this canister's config (token name/version, chainId, verifyingContract = the paid asset) and that the signer key controls the from address. Not retryable without re-signing.");
        };

        // Execute transferWithAuthorization on-chain (canister acts as facilitator)
        let sender = switch (evmSenderInst) {
          case (?s) { s };
          case (null) { nonceManager.unlock(signature.nonce); return #settlementFailed("EVM sender not configured") };
        };

        // H-4 (v2): Reserve the daily spend synchronously BEFORE the value-moving
        // await (this whole prefix runs atomically up to the await, so concurrent
        // charges can no longer each pass a stale daily-limit check). Released on
        // any settlement failure below — releasing against `evmSpendDay` (captured
        // now) so a rollback after the await targets the same bucket across midnight.
        let evmSpendDay = policy.currentDay();
        policy.recordSpend(evmSender, amount);

        let execResult = await sender.executeTransferWithAuthorization(
          chainId, tokenAddr,
          EvmUtils.hexToBytes(authz.from),
          EvmUtils.hexToBytes(authz.to),
          authz.value, authz.validAfter, authz.validBefore,
          Blob.toArray(authz.nonce),
          authz.v, Blob.toArray(authz.r), Blob.toArray(authz.s),
        );

        // Extract the broadcast tx hash. #maybeSent (ambiguous broadcast — post-dispatch error /
        // inconsistent RPC / nonce-too-high) carries a hash and MAY still mine, so route it into the
        // SAME confirm-poll instead of discarding it as a hash-less #settlementFailed (G5/G6). No
        // double-pay: the EIP-3009 token nonce is single-use on-chain, so if the tx already mined it
        // yields a receipt below, else it parks as #settlementPending WITH the hash (recoverable).
        let txHash = switch (execResult) {
          case (#err(msg)) {
            nonceManager.unlock(signature.nonce);
            policy.releaseDaily(evmSender, evmSpendDay, amount);
            return #settlementFailed("EIP-3009 execution failed: " # msg);
          };
          case (#ok(h)) { h };
          case (#maybeSent(m)) { m.txHash };
        };
        // H-1 (v2): Mempool acceptance is NOT settlement finality. Confirm the transfer actually
        // mined (status == 1) before issuing a receipt; an on-chain revert (insufficient balance,
        // reused token nonce, paused token) must not yield a "paid" receipt.
        switch (await sender.confirmTransaction(chainId, txHash, 4)) {
          case (#confirmed) {
            nonceManager.consumeLocked(signature.nonce);
            let receipt : Types.PaymentReceipt = {
              id = nextReceiptId();
              amount;
              token = tokenAddr;
              sender = authz.from;
              recipient = canisterEvmAddr;
              network = signature.network;
              timestamp = Time.now();
              txHash = ?txHash;
              sessionId = null;
              refunded = null;
            };
            return #ok(receipt);
          };
          case (#reverted) {
            nonceManager.unlock(signature.nonce);
            policy.releaseDaily(evmSender, evmSpendDay, amount);
            return #settlementFailed("EIP-3009 transfer reverted on-chain (tx " # txHash # ") — no funds moved and no receipt issued. Usual causes: payer USDC balance below value, authorization nonce already used, or token paused. Fix the cause and re-sign a fresh authorization.");
          };
          case (#pending) {
            // Keep the nonce locked (GC'd at expiry) so the same challenge is
            // not re-broadcast; release the daily reservation since no receipt
            // is issued. Caller MUST NOT deliver value on #settlementPending.
            policy.releaseDaily(evmSender, evmSpendDay, amount);
            return #settlementPending("EIP-3009 transfer broadcast but not yet confirmed (tx " # txHash # ") — NOT final: do not deliver value. Re-poll confirmEvmTransaction with this tx hash; the tx may still mine. Do not re-submit the same authorization (it is single-use on-chain).");
          };
          case (#err(e)) {
            policy.releaseDaily(evmSender, evmSpendDay, amount);
            return #settlementPending("EIP-3009 transfer broadcast; confirmation unavailable: " # e # " (tx " # txHash # ") — NOT final: do not deliver value. Transient RPC failure; re-poll confirmEvmTransaction with this tx hash rather than re-sending.");
          };
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

      // Validate sender before Principal.fromText (which traps on invalid input)
      if (signature.sender == "" or signature.sender.size() < 5) {
        nonceManager.unlock(signature.nonce);
        return #invalidSignature("Invalid sender principal: too short or empty");
      };
      let senderPrincipal = try {
        Principal.fromText(signature.sender);
      } catch (_) {
        nonceManager.unlock(signature.nonce);
        return #invalidSignature("Invalid sender principal: " # signature.sender);
      };

      switch (policy.checkCharge(senderPrincipal, amount)) {
        case (#denied(r)) { nonceManager.unlock(signature.nonce); return #policyDenied(r) };
        case (#ok) {};
      };

      let ledger : Types.LedgerActor = actor (Principal.toText(tokenConfig.ledger));

      // H-4 (v2): Reserve the daily spend synchronously before the transfer await
      // (closes the concurrent-charge daily-limit race); released on any failure
      // against `icpSpendDay` so a rollback after the await hits the same bucket.
      let icpSpendDay = policy.currentDay();
      policy.recordSpend(senderPrincipal, amount);

      try {
        let result = await ledger.icrc2_transfer_from({
          spender_subaccount = null;
          from = { owner = senderPrincipal; subaccount = null };
          to = recipientAccount();
          amount; // actual bound amount
          fee = null;
          memo = null;
          created_at_time = null;
        });

        switch (result) {
          case (#Ok(blockIndex)) {
            nonceManager.consumeLocked(signature.nonce);
            let receipt : Types.PaymentReceipt = {
              id = nextReceiptId();
              amount;
              token = Principal.toText(tokenConfig.ledger);
              sender = signature.sender;
              recipient = recipientText();
              network = signature.network;
              timestamp = Time.now();
              txHash = ?Nat.toText(blockIndex);
              sessionId = null;
              refunded = null;
            };
            #ok(receipt);
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
        nonceManager.unlock(signature.nonce);
        policy.releaseDaily(senderPrincipal, icpSpendDay, amount);
        #settlementFailed("Ledger call failed: " # Error.message(e));
      };
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

    /// Verify a cumulative voucher and return the delta.
    public func consumeVoucher(voucher : Types.Voucher) : Types.VoucherResult {
      sessionsMgr.consumeVoucher(voucher);
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
    /// H-5: Always refunds to payer, caps at unconsumed amount, rejects open sessions.
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
    public func sendErc20Transfer(chainId : Nat, token : Text, to : Text, amount : Nat) : async { #ok : Text; #err : Text } {
      switch (evmSenderInst) {
        case (?sender) {
          switch (await sender.sendErc20Transfer(chainId, token, to, amount)) {
            case (#ok(h)) { #ok(h) };
            case (#err(e)) { #err(e) };
            case (#maybeSent(m)) { #err(m.reason) };
          };
        };
        case (null) { #err("EVM not configured (no ecdsaKeyName)") };
      };
    };

    /// Confirmed variant: broadcasts AND polls the receipt, returning a tri-state so the
    /// caller finalizes state ONLY on #confirmed. The marketplace settle/refund + EVM
    /// session-close paths use this so an unconfirmed/reverted transfer is never treated
    /// as settled (B2). See EvmSender.sendErc20TransferConfirmed.
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
    public func setEvmChains(chains : [Types.EvmChainConfig]) : { #ok; #err : Text } {
      // Validation is all-or-nothing: a rejected set leaves the live set untouched. Beyond
      // the constructor's (nonexistent) checks, reject what would settle ambiguously or
      // brokenly; an empty list turns the EVM rail off, and zero-token chains are tolerated
      // and skipped by the advertising helpers, as at construction.
      var i = 0;
      for (chain in chains.vals()) {
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
        for (other in chains.vals()) {
          if (j < i and other.chainId == chain.chainId) {
            return #err("duplicate chainId " # Nat.toText(chain.chainId) # " — chain lookups resolve the FIRST match, so later duplicates would be dead config");
          };
          j += 1;
        };
        if (chain.recipient != "" and not isCanonicalEvmAddress(chain.recipient)) {
          return #err("chain " # Nat.toText(chain.chainId) # ": recipient must be a 0x-prefixed 20-byte hex address (advertised verbatim in 402 challenges): " # chain.recipient);
        };
        var t = 0;
        for (tok in chain.tokens.vals()) {
          if (not isCanonicalEvmAddress(tok.address)) {
            return #err("chain " # Nat.toText(chain.chainId) # ": token address must be a 0x-prefixed 20-byte hex address (advertised verbatim in 402 challenges): " # tok.address);
          };
          var u = 0;
          for (other in chain.tokens.vals()) {
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
    /// Also one-shot: auto-initializes the HMAC seed from raw_rand, and derives the canister's
    /// EVM address via tECDSA when config.ecdsaKeyName is set.
    /// Must be called from actor context (requires <system> capability). A consumer that does
    /// not call this must schedule closeExpiredSessions()/GC itself, or sessions never expire
    /// and rate-limit logs grow unbounded.
    ///
    /// CYCLES: the session sweep is SELF-ARMING (since 2.11.0) — it runs only while sessions
    /// exist and disarms itself when the last one is GC'd, so an idle canister is left with just
    /// the hourly GC tick below. A recurring timer is billed per tick regardless of what the
    /// callback does, which made the old always-on 60s sweep the largest fixed cost of embedding
    /// ic402 in a many-small-canisters topology. Confirm with sessionExpiryTimerArmed().
    public func startTimers<system>() {
      // Close expired sessions every 60 seconds, then GC stale entries. Armed unconditionally:
      // on upgrade a `persistent actor` re-runs its init body (where this call lives) BEFORE
      // postupgrade restores stable sessions, so gating the arm on "are there sessions?" would
      // leave exactly the canisters that DO have live sessions unswept. The first tick disarms
      // if there is nothing to do — at most one wasted tick per install/upgrade.
      sessionsMgr.armExpiryTimer<system>();
      // Garbage-collect stale policy data and revoked grants every hour
      ignore Timer.recurringTimer<system>(#seconds 3600, func() : async () {
        policy.gcDailySpend();
        // SEC-1: rateLimitLog is keyed on the (attacker-influenceable) payer principal on the
        // unauthenticated /settle path, so it can grow unbounded without this GC. gcRateLimit
        // was written for exactly this attack but was never wired to a timer — wire it here.
        policy.gcRateLimit();
        grants.gcRevokedGrants();
      });

      // Auto-init HMAC seed from randomness on first deployment
      ignore Timer.setTimer<system>(#seconds 0, func() : async () {
        let ic : actor { raw_rand : () -> async Blob } = actor "aaaaa-aa";
        let seed = await ic.raw_rand();
        ignore grants.initHmacSeed(seed);
      });

      // Auto-derive EVM address from tECDSA key if configured
      switch (config.ecdsaKeyName) {
        case (?keyName) {
          ignore Timer.setTimer<system>(#seconds 0, func() : async () {
            await deriveEvmRecipient(keyName);
          });
        };
        case (null) {};
      };
    };

    /// Whether the session-expiry sweep is currently armed. `false` on an idle canister is the
    /// expected steady state (nothing to expire ⇒ nothing ticking ⇒ no per-tick cycle burn);
    /// `true` while any session record exists. Pair it with sessionCounts() to explain a
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
    public func sessionCounts() : {
      total : Nat; open : Nat; closing : Nat; closed : Nat; expired : Nat;
    } {
      sessionsMgr.sessionCounts();
    };

    /// Opt-in (default OFF): require an ICP-rail session's Ed25519 voucher key to BE the caller's
    /// own IC identity key (self-authenticating principal check), so the session opener and its
    /// voucher signer are provably the same principal. Leave OFF unless every session client uses
    /// a raw Ed25519 identity — II delegations and secp256k1/P-256 callers would be rejected.
    /// ICP rail only (an EVM session's payer identity is the EVM address, not msg.caller).
    /// Transient: re-apply at init, like setPolicy/setEvmPoolCap.
    public func setRequireCallerBoundSessions(on : Bool) {
      sessionsMgr.setRequireCallerBoundSessions(on);
    };

    /// Whether a session's voucher key is the payer's own IC identity key (derived, works for
    /// pre-existing sessions). null = unknown session; false = "not identity-bound", never
    /// "invalid" — see Identity.selfAuthPrincipalOfEd25519 for the derivation and its limits.
    public func sessionCallerBound(sessionId : Text) : ?Bool {
      sessionsMgr.sessionCallerBound(sessionId);
    };

    /// Operator escape hatch: force a session stuck in #closing to a terminal state so it's
    /// GC-eligible (state assertion only — moves no funds). Controller-gate at the consumer.
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

    /// Recovery: confirm-only reconcile an EVM session parked in #closing (delegates to Sessions).
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

    /// Issue an access grant after successful payment.
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
    /// not decode blindly. Sessions restored while in #closing have no parked tx hash
    /// (transient); resolve them via forceResolveSession + out-of-band reconciliation.
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
