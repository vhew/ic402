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
import Char "mo:base/Char";
import Blob "mo:base/Blob";
import Array "mo:base/Array";
import HashMap "mo:base/HashMap";
import SHA256 "mo:sha2/Sha256";
import Utils "Utils";
import EvmVerify "EvmVerify";
import EvmAddress "EvmAddress";
import EvmEscrow "EvmEscrow";
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

  /// Main payment gateway. Orchestrates charges, sessions, grants, escrow, and policy.
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

    /// SEC-1 gate — call BEFORE parsing the facilitator body or running verifyPayment/settle.
    /// Returns #throttled when the global rate is exceeded, #lowCycles when the balance is below
    /// the floor (so an attacker can't drain the canister via the unmetered facilitator path).
    public func facilitatorAdmit() : { #ok; #throttled; #lowCycles } {
      if (Cycles.balance() < FACILITATOR_MIN_CYCLES) { return #lowCycles };
      let step = tokenBucketStep(facilitatorTokens, facilitatorLastRefill, Time.now(), FACILITATOR_BUCKET_CAPACITY, FACILITATOR_REFILL_PER_SEC);
      facilitatorTokens := step.tokens;
      facilitatorLastRefill := step.lastRefill;
      if (step.admit) { #ok } else { #throttled };
    };

    let sessionsMgr = SessionsMod.Sessions(
      selfPrincipal, config, policy, escrowManager,
      evmEscrowMgr, evmSenderInst,
      { get = func() : ?Text { evmRecipient } },
    );

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

    func recipientText() : Text {
      switch (config.recipient.subaccount) {
        case (null) { Principal.toText(config.recipient.owner) };
        case (?_) { Principal.toText(config.recipient.owner) };
      };
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

    // H-5: Validate that a text string contains only hex characters [0-9a-fA-F]
    func isHexString(s : Text) : Bool {
      for (c in s.chars()) {
        let n = Char.toNat32(c);
        let isHex = (n >= 48 and n <= 57) or (n >= 97 and n <= 102) or (n >= 65 and n <= 70);
        if (not isHex) return false;
      };
      true;
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

    /// Look up an EVM chain config by chain ID.
    func findEvmChain(chainId : Nat) : ?Types.EvmChainConfig {
      for (chain in config.evmChains.vals()) {
        if (chain.chainId == chainId) return ?chain;
      };
      null;
    };

    /// Find the configured EVM token on `chain` whose address matches `address`
    /// (case-insensitive). Used to select the EIP-712 domain (name/version) of the
    /// token actually being paid, rather than assuming tokens[0] — they differ on a
    /// multi-token chain, and a mismatched domain makes a valid signature fail.
    func findEvmToken(chain : Types.EvmChainConfig, address : Text) : ?Types.EvmTokenConfig {
      for (tok in chain.tokens.vals()) {
        if (EvmUtils.addressesEqual(tok.address, address)) return ?tok;
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
    public func requireEvm(amount : Nat) : [Types.PaymentRequirement] {
      if (amount == 0) { Debug.trap("ic402: requireEvm() called with amount = 0; payment amount must be positive") };
      let buf = Buffer.Buffer<Types.PaymentRequirement>(config.evmChains.size());
      for (chain in config.evmChains.vals()) {
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
    public func describeAll(amount : Nat) : [Types.PaymentRequirement] {
      let buf = Buffer.Buffer<Types.PaymentRequirement>(config.evmChains.size() + 1);
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
      for (chain in config.evmChains.vals()) {
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
      for (chain in config.evmChains.vals()) {
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
    /// PaymentRequirements OFF-CHAIN (no nonce, no broadcast, no state change). Returns the v2
    /// verify verdict {isValid, invalidReason?, payer?}. EVM-only — the ICP rail is non-standard
    /// and not exposed as a facilitator scheme. `asset` is the requirement's token (EIP-712
    /// verifyingContract); name/version come from the per-chain config.
    public func verifyPayment(signature : Types.PaymentSignature, expectedAmount : Nat, payTo : Text, asset : Text) : {
      isValid : Bool;
      invalidReason : ?Text;
      payer : ?Text;
    } {
      if (not isEvmNetwork(signature.network)) {
        return { isValid = false; invalidReason = ?"unsupported_scheme"; payer = null };
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
      var tokenName : ?Text = null;
      var tokenVersion : ?Text = null;
      switch (findEvmChain(chainId)) {
        case (?chain) {
          switch (findEvmToken(chain, asset)) {
            case (?tok) { tokenName := tok.name; tokenVersion := tok.version };
            case (null) { return { isValid = false; invalidReason = ?"unsupported_asset"; payer = ?authz.from } };
          };
        };
        case (null) { return { isValid = false; invalidReason = ?"invalid_network"; payer = ?authz.from } };
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

    /// Verify and settle a charge payment.
    /// Uses lock/consume/unlock pattern: nonce is locked during settlement,
    /// consumed on success, unlocked on failure (allowing client retry).
    /// Dispatches to ICRC-2 (ICP) or HTTPS outcall verification (EVM).
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

    /// Verify and settle a charge payment (ICP via ICRC-2 or EVM via EIP-3009).
    ///
    /// `expectedAmount` is the price the calling resource advertised. It is REQUIRED for a
    /// conformant x402 client that sends no ic402 server nonce (the EVM rail), and serves as a
    /// cross-resource guard for server-nonce clients (a nonce whose bound amount doesn't match
    /// the resource's price is rejected). Pass `null` to fall back to the nonce-bound amount.
    public func settle(signature : Types.PaymentSignature, expectedAmount : ?Nat) : async Types.PaymentResult {
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
          case (null) { return #expired("Nonce expired or already consumed") };
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
          case (_, false) { return #expired("ICP settlement requires the ic402 server nonce") };
          case (null, _) { return #expired("No server nonce and no resource amount; cannot settle") };
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
          case (null) { nonceManager.unlock(signature.nonce); return #settlementFailed("Canister EVM address not derived") };
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
        let tokenAddr = resolveTokenForNonce(signature.network);
        // M-5: Look up per-chain token name/version for the EIP-712 domain separator.
        // Return error if chain not configured (wrong defaults cause silent sig failure).
        var tokenName : ?Text = null;
        var tokenVersion : ?Text = null;
        switch (findEvmChain(chainId)) {
          case (?chain) {
            if (chain.tokens.size() > 0) {
              tokenName := chain.tokens[0].name;
              tokenVersion := chain.tokens[0].version;
            };
          };
          case (null) {
            nonceManager.unlock(signature.nonce);
            return #networkNotSupported("No EVM chain config for chainId " # Nat.toText(chainId));
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
          return #invalidSignature("EIP-3009 authorization signature verification failed");
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

        switch (execResult) {
          case (#err(msg)) {
            nonceManager.unlock(signature.nonce);
            policy.releaseDaily(evmSender, evmSpendDay, amount);
            return #settlementFailed("EIP-3009 execution failed: " # msg);
          };
          case (#ok(txHash)) {
            // H-1 (v2): Mempool acceptance is NOT settlement finality. Confirm the
            // transfer actually mined (status == 1) before issuing a receipt; an
            // on-chain revert (insufficient balance, reused token nonce, paused
            // token) must not yield a "paid" receipt.
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
                return #settlementFailed("EIP-3009 transfer reverted on-chain (tx " # txHash # ")");
              };
              case (#pending) {
                // Keep the nonce locked (GC'd at expiry) so the same challenge is
                // not re-broadcast; release the daily reservation since no receipt
                // is issued. Caller MUST NOT deliver value on #settlementPending.
                policy.releaseDaily(evmSender, evmSpendDay, amount);
                return #settlementPending("EIP-3009 transfer broadcast but not yet confirmed (tx " # txHash # ")");
              };
              case (#err(e)) {
                policy.releaseDaily(evmSender, evmSpendDay, amount);
                return #settlementPending("EIP-3009 transfer broadcast; confirmation unavailable: " # e # " (tx " # txHash # ")");
              };
            };
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
              case (#InsufficientFunds({ balance })) { #insufficientFunds("Insufficient funds: balance " # Nat.toText(balance)) };
              case (#InsufficientAllowance({ allowance })) { #insufficientFunds("Insufficient allowance: " # Nat.toText(allowance)) };
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

    /// Generate a session offer for 402 response.
    public func offerSession(intent : Types.SessionIntent) : Types.SessionIntent {
      sessionsMgr.offerSession(intent);
    };

    /// Open a session with ICRC-2 escrow deposit.
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
          #ok({
            id = nextReceiptId();
            amount = receipt.amount;
            token = receipt.token;
            sender = receipt.sender;
            recipient = receipt.recipient;
            network = receipt.network;
            timestamp = receipt.timestamp;
            txHash = receipt.txHash;
            sessionId = receipt.sessionId;
            refunded = receipt.refunded;
          });
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
          #ok({
            id = nextReceiptId();
            amount = receipt.amount;
            token = receipt.token;
            sender = receipt.sender;
            recipient = receipt.recipient;
            network = receipt.network;
            timestamp = receipt.timestamp;
            txHash = receipt.txHash;
            sessionId = receipt.sessionId;
            refunded = receipt.refunded;
          });
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
    /// ⚠️ UNCONFIRMED: #ok is only a mempool ack, NOT settlement finality, and #maybeSent
    /// is collapsed to #err here — callers MUST NOT finalize terminal state on #ok. Prefer
    /// `sendErc20TransferConfirmed` for any settle/refund path (B2). Retained for callers
    /// that confirm independently.
    public func sendErc20Transfer(chainId : Nat, token : Text, to : Text, amount : Nat) : async { #ok : Text; #err : Text } {
      switch (evmSenderInst) {
        case (?sender) {
          switch (await sender.sendErc20Transfer(chainId, token, to, amount)) {
            case (#ok(h)) { #ok(h) };
            case (#err(e)) { #err(e) };
            case (#maybeSent(e)) { #err(e) };
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

    /// Start recurring timers for session cleanup and policy garbage collection.
    /// Also auto-initializes HMAC seed and derives EVM address if ecdsaKeyName is set.
    /// Must be called from actor context (requires <system> capability).
    public func startTimers<system>() {
      // Close expired sessions every 60 seconds, then GC stale entries
      ignore Timer.recurringTimer<system>(#seconds 60, func() : async () {
        let _results = await sessionsMgr.closeExpiredSessions();
        // H-1: Remove closed/expired sessions older than 24h to prevent unbounded map growth
        sessionsMgr.gcClosedSessions();
      });
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

    // ── Policy ──

    /// Set spending policy: global (caller=null) or per-caller override.
    public func setPolicy(caller : ?Principal, p : Types.SpendingPolicy) {
      switch (caller) {
        case (null) { policy.setGlobalPolicy(p) };
        case (?c) { policy.setCallerPolicy(c, p) };
      };
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

    /// Serialize all gateway state for stable storage.
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

    /// Restore all gateway state from stable storage.
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
