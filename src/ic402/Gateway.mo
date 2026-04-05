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

module {

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
    public func settle(signature : Types.PaymentSignature) : async Types.PaymentResult {
      // H-2: Resolve token to verify nonce is bound to the correct network+token
      let resolvedToken = resolveTokenForNonce(signature.network);
      // Lock nonce and extract the bound payment amount
      let amount = switch (nonceManager.lock(signature.nonce, signature.network, resolvedToken)) {
        case (null) { return #expired("Nonce expired or already consumed") };
        case (?a) { a };
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
        if (authz.value < amount) {
          nonceManager.unlock(signature.nonce);
          return #insufficientFunds("Authorization value " # Nat.toText(authz.value) # " < required " # Nat.toText(amount));
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

        let execResult = await sender.executeTransferWithAuthorization(
          chainId, tokenAddr,
          EvmUtils.hexToBytes(authz.from),
          EvmUtils.hexToBytes(authz.to),
          authz.value, authz.validAfter, authz.validBefore,
          Blob.toArray(authz.nonce),
          authz.v, Blob.toArray(authz.r), Blob.toArray(authz.s),
        );

        switch (execResult) {
          case (#ok(txHash)) {
            nonceManager.consumeLocked(signature.nonce);
            policy.recordSpend(evmSender, amount);
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
          case (#err(msg)) {
            nonceManager.unlock(signature.nonce);
            return #settlementFailed("EIP-3009 execution failed: " # msg);
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
            policy.recordSpend(senderPrincipal, receipt.amount);
            #ok(receipt);
          };
          case (#Err(err)) {
            nonceManager.unlock(signature.nonce);
            switch (err) {
              case (#InsufficientFunds({ balance })) { #insufficientFunds("Insufficient funds: balance " # Nat.toText(balance)) };
              case (#InsufficientAllowance({ allowance })) { #insufficientFunds("Insufficient allowance: " # Nat.toText(allowance)) };
              case (_) { #settlementFailed("ICRC-2 error: " # debug_show(err)) };
            };
          };
        };
      } catch (e) {
        nonceManager.unlock(signature.nonce);
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

    /// Get the current daily spend total for a caller.
    public func dailySpend(caller : Principal) : Nat {
      policy.getDailySpendAmount(caller);
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
    public func verifyGrant(grant : Types.AccessGrant) : Types.AccessGrantResult {
      grants.verifyGrant(grant);
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
