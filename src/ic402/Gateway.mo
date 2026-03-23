/// ic402 — Main gateway class. Handles charges, sessions, and policy.
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
import Buffer "mo:base/Buffer";
import Principal "mo:base/Principal";
import Timer "mo:base/Timer";
import Error "mo:base/Error";
import Int "mo:base/Int";
import Blob "mo:base/Blob";
import Nat8 "mo:base/Nat8";
import Nat32 "mo:base/Nat32";
import Char "mo:base/Char";
import SHA256 "mo:sha2/Sha256";
import Ed25519 "mo:ed25519";
import EvmVerify "EvmVerify";

module {

  // HMAC-SHA256(key, message) → Blob
  func hmacSha256(key : [Nat8], message : [Nat8]) : Blob {
    let blockSize = 64;

    let effectiveKey : [Nat8] = if (key.size() > blockSize) {
      Blob.toArray(SHA256.fromArray(#sha256, key));
    } else {
      key;
    };

    let paddedKey = Array.tabulate<Nat8>(blockSize, func(i) : Nat8 {
      if (i < effectiveKey.size()) { effectiveKey[i] } else { 0 : Nat8 };
    });

    let ipadKey = Array.tabulate<Nat8>(blockSize, func(i) : Nat8 {
      paddedKey[i] ^ (0x36 : Nat8);
    });

    let opadKey = Array.tabulate<Nat8>(blockSize, func(i) : Nat8 {
      paddedKey[i] ^ (0x5c : Nat8);
    });

    let inner = SHA256.fromArray(#sha256, Array.append(ipadKey, message));
    SHA256.fromArray(#sha256, Array.append(opadKey, Blob.toArray(inner)));
  };

  func natToBytes8(n : Nat) : [Nat8] {
    var value = n;
    let bytes = Array.init<Nat8>(8, 0);
    var i = 7 : Nat;
    while (i > 0) {
      bytes[i] := Nat8.fromNat(value % 256);
      value := value / 256;
      i -= 1;
    };
    bytes[0] := Nat8.fromNat(value % 256);
    Array.freeze(bytes);
  };

  /// Encode a voucher payload as CBOR for Ed25519 signature verification.
  /// Must match the client-side encodeVoucherPayload() exactly:
  /// CBOR array(3): [text(sessionId), uint(cumulativeAmount), uint(sequence)]
  func encodeVoucherPayload(sessionId : Text, cumulativeAmount : Nat, sequence : Nat) : [Nat8] {
    // Manual CBOR encoding to avoid dependency on exact CBOR library API:
    // Array of 3 items: 0x83
    // Text string: 0x78 <len> <bytes> (for short strings: 0x60+len <bytes>)
    // Unsigned int: CBOR major type 0
    let sessionBytes = Blob.toArray(Text.encodeUtf8(sessionId));
    let buf = Buffer.Buffer<Nat8>(100);

    // CBOR array of 3 items
    buf.add(0x83);

    // Text string (sessionId)
    let sLen = sessionBytes.size();
    if (sLen < 24) {
      buf.add(Nat8.fromNat(0x60 + sLen));
    } else if (sLen < 256) {
      buf.add(0x78);
      buf.add(Nat8.fromNat(sLen));
    } else {
      buf.add(0x79);
      buf.add(Nat8.fromNat(sLen / 256));
      buf.add(Nat8.fromNat(sLen % 256));
    };
    for (b in sessionBytes.vals()) { buf.add(b) };

    // Unsigned integer (cumulativeAmount)
    encodeCborUint(buf, cumulativeAmount);

    // Unsigned integer (sequence)
    encodeCborUint(buf, sequence);

    Buffer.toArray(buf);
  };

  /// Encode a Nat as a CBOR unsigned integer (major type 0).
  func encodeCborUint(buf : Buffer.Buffer<Nat8>, n : Nat) {
    if (n < 24) {
      buf.add(Nat8.fromNat(n));
    } else if (n < 256) {
      buf.add(0x18);
      buf.add(Nat8.fromNat(n));
    } else if (n < 65536) {
      buf.add(0x19);
      buf.add(Nat8.fromNat(n / 256));
      buf.add(Nat8.fromNat(n % 256));
    } else if (n < 4294967296) {
      buf.add(0x1a);
      buf.add(Nat8.fromNat((n / 16777216) % 256));
      buf.add(Nat8.fromNat((n / 65536) % 256));
      buf.add(Nat8.fromNat((n / 256) % 256));
      buf.add(Nat8.fromNat(n % 256));
    } else {
      buf.add(0x1b);
      let bytes = natToBytes8(n);
      for (b in bytes.vals()) { buf.add(b) };
    };
  };

  public class Gateway(config : Types.Config, selfPrincipal : Principal) {

    let policy = Policy.Engine();
    let nonceManager = Nonce.NonceManager(selfPrincipal);
    let escrowManager = Escrow.EscrowManager(selfPrincipal);

    var sessions = HashMap.HashMap<Text, Types.InternalSessionState>(16, Text.equal, Text.hash);
    var receiptCounter : Nat = 0;
    var grantCounter : Nat = 0;
    var hmacSeed : Nat = 0;
    var revokedGrants = HashMap.HashMap<Text, Bool>(16, Text.equal, Text.hash);

    func hmacSecret() : [Nat8] {
      let principalBytes = Blob.toArray(Principal.toBlob(selfPrincipal));
      let seedBytes = natToBytes8(hmacSeed);
      Blob.toArray(SHA256.fromArray(#sha256, Array.append(principalBytes, seedBytes)));
    };

    func computeGrantHmac(grantId : Text, grantee : Principal, expiresAt : Int) : Blob {
      let message = grantId # "|" # Principal.toText(grantee) # "|" # Int.toText(expiresAt);
      hmacSha256(hmacSecret(), Blob.toArray(Text.encodeUtf8(message)));
    };

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

    /// Extract chain ID from CAIP-2 network string (e.g. "eip155:43113" → 43113).
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
        let evmResult = await settleEvm(signature, amount);
        switch (evmResult) {
          case (#ok(_)) { nonceManager.consumeLocked(signature.nonce) };
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

      let senderPrincipal = Principal.fromText(signature.sender);

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
            policy.recordSpend(Principal.fromText(signature.sender), receipt.amount);
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
      let fee : Nat = 10_000; // default ICRC-1 fee — in production, query icrc1_fee
      let settleFees = if (session.consumed > 0) { fee } else { 0 };
      let escrowBalance = if (session.deposited > session.consumed + settleFees) {
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

    // ── Content Delivery ──

    /// Issue an access grant after successful payment.
    public func issueGrant(
      contentRef : Types.ContentRef,
      grantee : Principal,
      receiptId : Text,
      ttlNanos : Int,
    ) : Types.AccessGrant {
      grantCounter += 1;
      let grantId = "grant-" # Nat.toText(grantCounter);
      let now = Time.now();
      let expiresAt = now + ttlNanos;
      let hmac = computeGrantHmac(grantId, grantee, expiresAt);

      {
        grantId;
        contentRef;
        grantee;
        receiptId;
        issuedAt = now;
        expiresAt;
        hmac;
      };
    };

    /// Verify an access grant (stateless HMAC check + expiry + revocation).
    public func verifyGrant(grant : Types.AccessGrant) : Types.AccessGrantResult {
      switch (revokedGrants.get(grant.grantId)) {
        case (?_) { return #revoked };
        case (null) {};
      };

      if (Time.now() > grant.expiresAt) {
        return #expired;
      };

      let expected = computeGrantHmac(grant.grantId, grant.grantee, grant.expiresAt);
      if (expected != grant.hmac) {
        return #invalidGrant;
      };

      #ok;
    };

    /// Revoke a grant (e.g., after refund).
    public func revokeGrant(grantId : Text) : Bool {
      switch (revokedGrants.get(grantId)) {
        case (?_) { false };
        case (null) {
          revokedGrants.put(grantId, true);
          true;
        };
      };
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
        accessGrants = ?{
          revokedGrantIds = Iter.toArray(
            Iter.map<(Text, Bool), Text>(
              revokedGrants.entries(),
              func((id, _)) { id },
            )
          );
          grantCounter;
          hmacSeed;
        };
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

      switch (data.accessGrants) {
        case (?grants) {
          grantCounter := grants.grantCounter;
          hmacSeed := grants.hmacSeed;
          revokedGrants := HashMap.HashMap<Text, Bool>(
            grants.revokedGrantIds.size(), Text.equal, Text.hash,
          );
          for (id in grants.revokedGrantIds.vals()) {
            revokedGrants.put(id, true);
          };
        };
        case (null) {};
      };
    };
  };
};
