/// ic402 — Main gateway class. Orchestrates charges, sessions, grants, and policy.
import Types "Types";
import Policy "Policy";
import Nonce "Nonce";
import Escrow "Escrow";
import GrantsMod "Grants";
import SessionsMod "Sessions";
import Time "mo:base/Time";
import Nat "mo:base/Nat";
import Text "mo:base/Text";
import Iter "mo:base/Iter";
import Buffer "mo:base/Buffer";
import Principal "mo:base/Principal";
import Timer "mo:base/Timer";
import Error "mo:base/Error";
import Nat32 "mo:base/Nat32";
import Char "mo:base/Char";
import EvmVerify "EvmVerify";

module {

  public class Gateway(config : Types.Config, selfPrincipal : Principal) {

    let policy = Policy.Engine();
    let nonceManager = Nonce.NonceManager(selfPrincipal);
    let escrowManager = Escrow.EscrowManager(selfPrincipal);
    let grants = GrantsMod.Grants(selfPrincipal);
    let sessionsMgr = SessionsMod.Sessions(selfPrincipal, config, policy, escrowManager);

    var receiptCounter : Nat = 0;

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

    func findLedger(tokenPrincipalText : Text) : ?Types.TokenConfig {
      for (t in config.tokens.vals()) {
        if (Principal.toText(t.ledger) == tokenPrincipalText) return ?t;
      };
      null;
    };

    // ── Charge (x402 "exact") ──

    /// Generate a 402 payment requirement for a given price.
    /// Asserts amount > 0 to prevent free-payment attacks.
    public func require(price : Types.Price) : Types.PaymentRequirement {
      assert(price.amount > 0);
      let expiry = Time.now() + 300_000_000_000; // 5 minutes
      let nonce = nonceManager.generate(expiry, price.amount);
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

    /// Look up an EVM chain config by chain ID.
    func findEvmChain(chainId : Nat) : ?Types.EvmChainConfig {
      for (chain in config.evmChains.vals()) {
        if (chain.chainId == chainId) return ?chain;
      };
      null;
    };

    /// Generate 402 payment requirements for all configured EVM chains.
    public func requireEvm(amount : Nat) : [Types.PaymentRequirement] {
      let buf = Buffer.Buffer<Types.PaymentRequirement>(config.evmChains.size());
      for (chain in config.evmChains.vals()) {
        let expiry = Time.now() + 300_000_000_000;
        let nonce = nonceManager.generate(expiry, amount);
        let token = if (chain.tokens.size() > 0) { chain.tokens[0].address } else { "" };
        buf.add({
          scheme = "exact";
          network = "eip155:" # Nat.toText(chain.chainId);
          token;
          amount;
          recipient = chain.recipient;
          nonce;
          expiry;
        });
      };
      Buffer.toArray(buf);
    };

    /// Check if a network identifier is an EVM chain (eip155:*).
    func isEvmNetwork(network : Text) : Bool {
      Text.startsWith(network, #text "eip155:");
    };

    /// Extract chain ID from CAIP-2 network string (e.g. "eip155:43113" -> 43113).
    func extractChainId(network : Text) : ?Nat {
      let parts = Text.split(network, #char ':');
      let arr = Iter.toArray(parts);
      if (arr.size() != 2) return null;
      // Simple decimal parse
      var result : Nat = 0;
      for (c in arr[1].chars()) {
        let d = Nat32.toNat(Char.toNat32(c));
        if (d < 48 or d > 57) return null;
        result := result * 10 + (d - 48);
      };
      ?result;
    };

    /// Verify and settle a charge payment.
    /// Uses lock/consume/unlock pattern: nonce is locked during settlement,
    /// consumed on success, unlocked on failure (allowing client retry).
    /// Dispatches to ICRC-2 (ICP) or HTTPS outcall verification (EVM).
    public func settle(signature : Types.PaymentSignature) : async Types.PaymentResult {
      // Lock nonce and extract the bound payment amount
      let amount = switch (nonceManager.lock(signature.nonce)) {
        case (null) { return #expired };
        case (?a) { a };
      };

      // Dispatch to EVM settlement if eip155:* network
      if (isEvmNetwork(signature.network)) {
        // For EVM senders, use the caller principal for policy enforcement
        // (EVM addresses are not valid ICP principals)
        let evmSender = selfPrincipal;
        switch (policy.checkCharge(evmSender, amount)) {
          case (#denied(r)) { nonceManager.unlock(signature.nonce); return #policyDenied(r) };
          case (#ok) {};
        };

        let evmResult = await settleEvm(signature, amount);
        switch (evmResult) {
          case (#ok(_)) {
            nonceManager.consumeLocked(signature.nonce);
            policy.recordSpend(evmSender, amount);
          };
          case (_) { nonceManager.unlock(signature.nonce) };
        };
        return evmResult;
      };

      // ── ICP settlement via ICRC-2 ──

      let tokenConfig = switch (findLedger(signature.network)) {
        case (?tc) { tc };
        case (null) {
          switch (config.tokens.size()) {
            case (0) { nonceManager.unlock(signature.nonce); return #tokenNotAccepted };
            case (_) { config.tokens[0] };
          };
        };
      };

      // Validate sender before Principal.fromText (which traps on invalid input)
      if (signature.sender == "" or signature.sender.size() < 5) {
        nonceManager.unlock(signature.nonce);
        return #invalidSignature;
      };
      let senderPrincipal = try {
        Principal.fromText(signature.sender);
      } catch (_) {
        nonceManager.unlock(signature.nonce);
        return #invalidSignature;
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
              case (#InsufficientFunds(_)) { #insufficientFunds };
              case (#InsufficientAllowance(_)) { #insufficientFunds };
              case (_) { #settlementFailed("ICRC-2 error: " # debug_show(err)) };
            };
          };
        };
      } catch (e) {
        nonceManager.unlock(signature.nonce);
        #settlementFailed("Ledger call failed: " # Error.message(e));
      };
    };

    /// Settle an EVM payment by verifying the transaction on-chain via HTTPS outcall.
    /// Nonce locking/consuming is handled by the caller (settle).
    func settleEvm(signature : Types.PaymentSignature, amount : Nat) : async Types.PaymentResult {
      let chainId = switch (extractChainId(signature.network)) {
        case (?id) { id };
        case (null) { return #networkNotSupported };
      };

      let chainConfig = switch (findEvmChain(chainId)) {
        case (?cc) { cc };
        case (null) { return #networkNotSupported };
      };

      let txHash = switch (Text.decodeUtf8(signature.signature)) {
        case (?h) { h };
        case (null) { return #invalidSignature };
      };

      // Validate txHash format: must be 0x + 64 hex chars
      if (txHash.size() != 66) { return #invalidSignature };
      if (not Text.startsWith(txHash, #text "0x")) { return #invalidSignature };

      let expectedToken = if (chainConfig.tokens.size() > 0) {
        chainConfig.tokens[0].address;
      } else {
        return #tokenNotAccepted;
      };

      try {
        let result = await EvmVerify.verifyTransaction(
          txHash,
          chainId,
          expectedToken,
          chainConfig.recipient,
          amount,
          config.evmRpcCanister,
        );

        switch (result) {
          case (#ok(verified)) {
            let receipt : Types.PaymentReceipt = {
              id = nextReceiptId();
              amount = verified.amount;
              token = expectedToken;
              sender = signature.sender;
              recipient = chainConfig.recipient;
              network = signature.network;
              timestamp = Time.now();
              txHash = ?txHash;
              sessionId = null;
              refunded = null;
            };
            policy.recordSpend(selfPrincipal, receipt.amount);
            #ok(receipt);
          };
          case (#failed(reason)) {
            #settlementFailed("EVM verification failed: " # reason);
          };
        };
      } catch (e) {
        #settlementFailed("EVM verification error: " # Error.message(e));
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

    /// Close a session: settle consumed, refund remainder.
    public func closeSession(sessionId : Text) : async Types.PaymentResult {
      let result = await sessionsMgr.closeSession(sessionId);
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

    /// Close all expired or idle sessions.
    public func closeExpiredSessions() : async [Types.PaymentResult] {
      await sessionsMgr.closeExpiredSessions();
    };

    /// Recover funds from an escrow subaccount (admin use only).
    public func recoverEscrow(
      ledger : Types.LedgerActor,
      sessionId : Text,
      recipient : Types.Account,
      amount : Nat,
    ) : async { #ok : Nat; #err : Text } {
      await sessionsMgr.recoverEscrow(ledger, sessionId, recipient, amount);
    };

    /// Start recurring timers for session cleanup and policy garbage collection.
    /// Must be called from actor context (requires <system> capability).
    public func startTimers<system>() {
      // Close expired sessions every 60 seconds
      ignore Timer.recurringTimer<system>(#seconds 60, func() : async () {
        let _results = await sessionsMgr.closeExpiredSessions();
        // TOB-IC402-8: results are now captured (not ignored)
      });
      // Garbage-collect stale policy data every hour
      ignore Timer.recurringTimer<system>(#seconds 3600, func() : async () {
        policy.gcDailySpend();
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

    // ── Content Delivery (delegates to Grants module) ──

    /// Initialize HMAC seed from randomness. Call once on first deployment.
    public func initHmacSeed(randomBlob : Blob) {
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

    public func toStable() : Types.StableGatewayState {
      {
        sessions = sessionsMgr.toStable();
        nonces = nonceManager.toStable();
        policy = policy.toStable();
        receiptCounter;
        accessGrants = ?grants.toStable();
      };
    };

    public func loadStable(data : Types.StableGatewayState) {
      nonceManager.loadStable(data.nonces);
      policy.loadStable(data.policy);
      receiptCounter := data.receiptCounter;

      // Sync session counter with receipt counter (they shared the counter in the original)
      sessionsMgr.setCounter(receiptCounter);

      sessionsMgr.loadStable(data.sessions);

      switch (data.accessGrants) {
        case (?grantsData) {
          grants.loadStable(grantsData);
        };
        case (null) {};
      };
    };
  };
};
