/// ic402 — EVM transaction sender via tECDSA.
///
/// Signs and submits EVM transactions using the canister's threshold ECDSA key.
/// Provides both generic transaction sending and ERC-20 transfer helpers.

import EvmUtils "EvmUtils";
import EvmRpc "EvmRpc";
import EvmAddress "EvmAddress";
import Blob "mo:base/Blob";
import Array "mo:base/Array";
import Nat "mo:base/Nat";
import Buffer "mo:base/Buffer";
import Nat8 "mo:base/Nat8";
import Error "mo:base/Error";
import HashMap "mo:base/HashMap";
import Text "mo:base/Text";
import Iter "mo:base/Iter";
import Cycles "mo:base/ExperimentalCycles";
import IC "mo:ic";
import Call "mo:ic/Call";
import SchnorrSigner "SchnorrSigner";

module {

  /// The outcome of an outbound send. #err: the tx was definitely NOT broadcast (safe to roll
  /// back and retry). #maybeSent: it may be on chain; the caller must confirm-poll `txHash`, never
  /// re-broadcast. #ok: accepted, with its hash.
  public type SendOutcome = { #ok : Text; #err : Text; #maybeSent : { txHash : Text; reason : Text } };

  /// 2.21.1: classify an eth_sendRawTransaction result. Only failures raised before anything was
  /// sent are #err. Everything after dispatch is #maybeSent, because a send is not idempotent: a
  /// node whose copy arrives after another node's copy was included answers "nonce too low" for
  /// that SAME tx, and with a 2-of-N threshold over the Ok statuses a third provider may have
  /// accepted a tx the agreeing two refused. A consistent RPC #Err needs every provider to agree,
  /// but it still comes after dispatch (an outcall timeout may have delivered the tx). Before
  /// 2.21.1 a consistent NonceTooLow or RPC error was #err, so callers rolled back and sent again —
  /// a second transfer when the first had landed. Residual: InsufficientFunds stays #err here (an
  /// unfunded gas account must not park every send), although under the threshold a third
  /// provider that already saw a gas top-up could have accepted the tx. 2.22.0: sendTransaction
  /// re-reads the pending nonce after an InsufficientFunds answer and reports #maybeSent when it
  /// moved past the tx's nonce; a tx held by a provider whose view the agreeing providers do not
  /// share yet is still missed. The full fix, re-sending the same signed bytes, is planned.
  /// `broadcastTxHash` is the locally derived hash of the signed raw tx, always pollable.
  public func classifySend(r : EvmRpc.MultiSendRawTransactionResult, broadcastTxHash : Text) : SendOutcome {
    switch (r) {
      case (#Consistent(#Ok(#Ok(?hash)))) { #ok(hash) };
      // Accepted with no hash echoed — use the locally derived canonical hash, NOT the raw tx.
      case (#Consistent(#Ok(#Ok(null)))) { #ok(broadcastTxHash) };
      case (#Consistent(#Ok(#NonceTooLow))) {
        #maybeSent({ txHash = broadcastTxHash; reason = "Nonce too low — this tx may already have been included (a send is not idempotent); confirming instead of re-sending" });
      };
      // Queued in the mempool (nonce ahead) — it can still mine.
      case (#Consistent(#Ok(#NonceTooHigh))) { #maybeSent({ txHash = broadcastTxHash; reason = "Nonce too high (tx may be queued in mempool)" }) };
      case (#Consistent(#Ok(#InsufficientFunds))) { #err("Insufficient ETH for gas — the canister's derived EVM address pays gas for broadcasts. Fund it with the chain's native token (getEvmAddress()/getEvmRecipient() shows the address) and retry; nothing was broadcast.") };
      // Raised by the EVM-RPC canister before any provider was called.
      case (#Consistent(#Err(#ProviderError(e)))) { #err("RPC error before sending: " # EvmRpc.rpcErrorToText(#ProviderError(e))) };
      case (#Consistent(#Err(#ValidationError(e)))) { #err("RPC error before sending: " # EvmRpc.rpcErrorToText(#ValidationError(e))) };
      // A node error or an outcall error: the tx may have reached a provider.
      case (#Consistent(#Err(e))) { #maybeSent({ txHash = broadcastTxHash; reason = "RPC error after dispatch (may have broadcast): " # EvmRpc.rpcErrorToText(e) }) };
      // Providers disagree — one may have accepted the tx into its mempool.
      case (#Inconsistent(_)) { #maybeSent({ txHash = broadcastTxHash; reason = "Inconsistent RPC responses (a provider may have accepted the tx)" }) };
    };
  };

  /// 2.22.0: the single-flight lock's refusal, verbatim. Named so a caller can tell this
  /// transient, nothing-broadcast refusal from the other pre-broadcast errors (`isSendBusy`).
  public let SEND_BUSY : Text = "Another outbound EVM transaction is in progress — sends are serialized to keep the nonce consistent. Nothing was broadcast; retry in a few seconds.";

  /// 2.22.0: true when a send's #err is the busy single-flight lock (SEND_BUSY), which clears by
  /// itself once the send holding the lock returns.
  public func isSendBusy(err : Text) : Bool { err == SEND_BUSY };

  /// 2.22.0 (F1): whether a tx signed with account nonce `txNonce` can still land, given the
  /// account's mined-transaction count `latestNonce` (eth_getTransactionCount at #Latest). Once
  /// the count passes the tx's nonce, a transaction with that nonce has been mined; if no receipt
  /// exists for this tx's hash, it was another one, and this tx can never be included.
  public func txNonceConsumed(txNonce : Nat, latestNonce : Nat) : Bool { latestNonce > txNonce };

  // ── EIP-3009 authorizationState (2.22.0, E7) ──

  /// What `authorizationState(authorizer, nonce)` says about an EIP-3009 authorization: #used
  /// (executed by some transaction, or cancelled by the payer — the token does not say which),
  /// #unused, or #unknown when the read failed or was ambiguous.
  public type AuthorizationState = { #used; #unused; #unknown : Text };

  /// Calldata for the EIP-3009 view `authorizationState(address authorizer, bytes32 nonce)`.
  /// `authorizer` must be 20 bytes and `authNonce` 32 (callers check; the ABI encoder traps).
  public func buildAuthorizationStateCalldata(authorizer : [Nat8], authNonce : [Nat8]) : [Nat8] {
    EvmUtils.abiEncodeFunctionCall(
      EvmUtils.functionSelector("authorizationState(address,bytes32)"),
      [#static_(EvmUtils.natToBytes(EvmUtils.bytesToNat(authorizer), 32)), #static_(authNonce)],
    );
  };

  /// Decode return data holding exactly one ABI `bool` word. null on anything else.
  public func decodeAbiBool(hex : Text) : ?Bool {
    let bytes = EvmUtils.hexToBytes(hex);
    if (bytes.size() != 32) return null;
    switch (EvmUtils.bytesToNat(bytes)) {
      case (0) { ?false };
      case (1) { ?true };
      case (_) { null };
    };
  };

  /// Classify an eth_call of authorizationState. Only a consistent, well-formed answer counts.
  public func classifyAuthorizationState(r : EvmRpc.MultiCallResult) : AuthorizationState {
    switch (r) {
      case (#Consistent(#Ok(hex))) {
        switch (decodeAbiBool(hex)) {
          case (?true) { #used };
          case (?false) { #unused };
          case (null) { #unknown("authorizationState returned an unexpected value: " # hex) };
        };
      };
      case (#Consistent(#Err(e))) { #unknown("authorizationState call failed: " # EvmRpc.rpcErrorToText(e)) };
      case (#Inconsistent(_)) { #unknown("authorizationState: providers disagree") };
    };
  };

  // ── Broadcast EIP-3009 authorizations (2.22.0, E5) ──

  /// 2.22.0 (E5): the answer to a settle (Gateway) or session open (Sessions) whose EIP-3009 authorization this
  /// canister has already broadcast. Pending, not failed: the earlier broadcast may have paid.
  public func alreadyBroadcastText(txHash : ?Text) : Text {
    let tx = switch (txHash) { case (?h) { " in tx " # h }; case (null) { " (that broadcast is still in flight)" } };
    "This EIP-3009 authorization was already broadcast by this canister" # tx
    # " — it is not broadcast again. Do NOT sign a new payment until that tx resolves: re-poll"
    # " confirmEvmTransaction with its hash. If it reverted and authorizationState shows the"
    # " authorization unused on chain, sign a fresh one.";
  };


  /// The EIP-3009 authorizations a sender has broadcast, so the same one is never broadcast
  /// twice. An authorization is single-use on chain, so a second broadcast can only revert — and
  /// the canister pays its gas and holds the single-flight send lock while it does. Before 2.22.0
  /// anyone holding a payer's authorization (a replay of a settled one, or a payer's own retry)
  /// could make the canister broadcast it again.
  ///
  /// Keyed by (chainId, token, from, nonce) — authorizationState is per token contract — on
  /// decoded bytes, so hex case and the 0x prefix do not split one authorization into two.
  /// An entry is claimed synchronously before the broadcast's first await (so two concurrent
  /// settles of one authorization cannot both send), released when the send fails before
  /// broadcast, and otherwise kept until the authorization's validBefore, capped at 24 hours;
  /// the chain refuses it after validBefore anyway. At most 10_000 entries: when full, expired
  /// entries are dropped first, then the one expiring soonest, so an attacker filling the set
  /// (each entry costs the canister a broadcast) can at worst re-enable one replay per entry
  /// evicted. Transient: an upgrade forgets it, which re-allows one replay per authorization.
  public class AuthorizationGuard() {
    let MAX_ENTRIES : Nat = 10_000;
    let MAX_TTL_SECONDS : Nat = 86_400;
    let entries = HashMap.HashMap<Text, { expiresAt : Nat; txHash : ?Text }>(16, Text.equal, Text.hash);

    /// The guard key of an authorization.
    public func key(chainId : Nat, token : Text, from : [Nat8], authNonce : [Nat8]) : Text {
      Nat.toText(chainId) # ":" # EvmUtils.bytesToHex(EvmUtils.hexToBytes(token)) # ":" # EvmUtils.bytesToHex(from) # ":" # EvmUtils.bytesToHex(authNonce);
    };

    /// Claim `k` for a broadcast. #seen(txHash) when it is already claimed and not expired —
    /// txHash is null while that broadcast is still in flight.
    public func claim(k : Text, validBefore : Nat, nowSeconds : Nat) : { #ok; #seen : ?Text } {
      switch (entries.get(k)) {
        case (?e) { if (e.expiresAt > nowSeconds) { return #seen(e.txHash) } };
        case (null) {};
      };
      if (entries.size() >= MAX_ENTRIES) { prune(nowSeconds) };
      entries.put(k, { expiresAt = Nat.min(validBefore, nowSeconds + MAX_TTL_SECONDS); txHash = null });
      #ok;
    };

    /// Forget `k`: its send failed before anything was broadcast, so it may be sent again.
    public func release(k : Text) { entries.delete(k) };

    /// Record the hash of the tx that broadcast `k`, so a refused replay can name it.
    public func noteTx(k : Text, txHash : Text) {
      switch (entries.get(k)) {
        case (?e) { entries.put(k, { e with txHash = ?txHash }) };
        case (null) {};
      };
    };

    /// Number of remembered authorizations (expired ones included until pruned).
    public func size() : Nat { entries.size() };

    func prune(nowSeconds : Nat) {
      for ((k, e) in Iter.toArray(entries.entries()).values()) {
        if (e.expiresAt <= nowSeconds) { entries.delete(k) };
      };
      if (entries.size() >= MAX_ENTRIES) {
        var soonest : ?(Text, Nat) = null;
        for ((k, e) in entries.entries()) {
          switch (soonest) {
            case (?(_, at)) { if (e.expiresAt < at) { soonest := ?(k, e.expiresAt) } };
            case (null) { soonest := ?(k, e.expiresAt) };
          };
        };
        switch (soonest) { case (?(k, _)) { entries.delete(k) }; case (null) {} };
      };
    };
  };

  // ── Pure fee helpers (module scope so they're unit-testable) ──

  /// Pick the latest base fee from one provider's FeeHistory: prefer the forecast
  /// next-block base fee (index 1, as the original did), then the current block
  /// (index 0); null on an empty array so callers distinguish "no data" from a real 0.
  public func latestBaseFee(history : EvmRpc.FeeHistory) : ?Nat {
    if (history.baseFeePerGas.size() > 1) { ?history.baseFeePerGas[1] } else if (history.baseFeePerGas.size() > 0) {
      ?history.baseFeePerGas[0];
    } else { null };
  };

  /// Convert a base fee into the (maxFeePerGas, maxPriorityFeePerGas) pair — the
  /// exact formula the original #Consistent path used: priority fee = base fee
  /// clamped to [1e6, 1.5 gwei]; maxFee = 2*base + priority.
  ///
  /// S16: clamp the base fee to a sane ceiling (10_000 gwei — orders of magnitude
  /// above any real L1/L2 base fee, far below a balance-busting value) FIRST. Since
  /// fee data no longer requires strict multi-provider agreement (see getFeeData),
  /// a single hostile or buggy RPC provider could otherwise return an absurd base
  /// fee that inflates maxFeePerGas into an unpayable upfront gas reservation
  /// (gasLimit * maxFeePerGas), tripping eth_sendRawTransaction's balance check and
  /// parking every transfer. The cap bounds that. It also hardens the #Consistent
  /// path, which previously had no ceiling either.
  public func feeFromBase(rawBaseFee : Nat) : (Nat, Nat) {
    let baseFee = Nat.min(rawBaseFee, 10_000_000_000_000);
    let minPriority = 1_000_000;
    let priorityFee = if (baseFee > 1_500_000_000) { 1_500_000_000 } else if (baseFee > minPriority) { baseFee } else {
      minPriority;
    };
    (2 * baseFee + priorityFee, priorityFee);
  };

  /// SEC-2: a ROBUST central base fee across the providers that returned data — the lower median —
  /// so a single hostile/buggy provider reporting an EXTREME base fee cannot push the gas reservation
  /// (gasLimit * maxFeePerGas) to an unpayable value and grief-park every close/settle. The prior fold
  /// took the MAX, which picked exactly that outlier. With ≥3 providers this is the true middle
  /// (ignores one high AND one low outlier); with 2 it is the lower of the pair (neutralises a high
  /// outlier). The 2x multiplier in feeFromBase, the 10k-gwei cap there, and the confirm-only reconcile
  /// path cover the residual underpay risk if the low value is the wrong one. Returns null only when no
  /// provider produced a base fee. Pure — unit-tested.
  public func robustBaseFee(bases : [Nat]) : ?Nat {
    if (bases.size() == 0) return null;
    let sorted = Array.sort(bases, Nat.compare);
    ?sorted[(sorted.size() - 1) / 2];
  };

  /// Build the EIP-3009 `transferWithAuthorization` calldata (selector 0xe3ee160e).
  /// Pure + module-scoped so the on-chain encoding is unit-testable WITHOUT a broadcast
  /// (that opacity is exactly what let the v-form bug reach mainnet).
  ///
  /// MONEY-PATH INVARIANT: the payer's signature `v` arrives here in ic402's internal 0/1
  /// recovery-id form (HttpHandler normalized it for ecRecover). USDC's on-chain `ecrecover`
  /// requires 27/28, so the v word is denormalized via `chainVFromRecoveryId`. Encoding the
  /// raw 0/1 makes the contract recover the wrong signer and REVERT — no funds move.
  public func buildTransferWithAuthorizationCalldata(
    from : [Nat8],       // 20 bytes
    to : [Nat8],         // 20 bytes
    value : Nat,
    validAfter : Nat,
    validBefore : Nat,
    authNonce : [Nat8],  // 32 bytes
    v : Nat8,            // 0/1 recovery id (as normalized on ingress)
    r : [Nat8],          // 32 bytes
    s : [Nat8],          // 32 bytes
  ) : [Nat8] {
    let selector : [Nat8] = [0xe3, 0xee, 0x16, 0x0e];
    EvmUtils.abiEncodeFunctionCall(
      selector,
      [
        #static_(EvmUtils.natToBytes(EvmUtils.bytesToNat(from), 32)),                        // from (address)
        #static_(EvmUtils.natToBytes(EvmUtils.bytesToNat(to), 32)),                          // to (address)
        #static_(EvmUtils.abiEncodeUint256(value)),                                          // value
        #static_(EvmUtils.abiEncodeUint256(validAfter)),                                     // validAfter
        #static_(EvmUtils.abiEncodeUint256(validBefore)),                                    // validBefore
        #static_(authNonce),                                                                  // nonce (bytes32)
        #static_(EvmUtils.abiEncodeUint256(Nat8.toNat(EvmUtils.chainVFromRecoveryId(v)))),  // v (27/28 on-chain form)
        #static_(r),                                                                          // r (bytes32)
        #static_(s),                                                                          // s (bytes32)
      ],
    );
  };

  /// EVM transaction sender with tECDSA signing.
  /// `derivationPath` is fixed for the life of the instance — an EVM address derived under a
  /// path is PUBLISHED, and a published address must never move. Construct through
  /// `EvmSender(keyName, rpc)` (empty path, the pre-2.16.0 behaviour) or `EvmSenderAt(...)`
  /// (validated). It must match the path of the signer and gateway recipient it settles for —
  /// see `Gateway.deriveEvmRecipientAt`.
  public class Sender(ecdsaKeyName : Text, evmRpcCanister : ?Text, derivationPath : [Blob]) {

    var cachedPubKey : ?[Nat8] = null;
    var cachedEvmAddr : ?Text = null;
    // H-1: Serialize EVM transactions to prevent nonce desync on concurrent calls.
    var txInProgress : Bool = false;

    /// 2.22.0 (E5): the EIP-3009 authorizations this sender has broadcast (see AuthorizationGuard).
    /// Gateway.settle and the session-open deposit claim here before broadcasting; a direct caller
    /// of executeTransferWithAuthorization is not checked.
    public let broadcastAuthorizations : AuthorizationGuard = AuthorizationGuard();

    // 2.22.0 (F1): the account nonce each tx this sender signed was sent with, by lower-case tx
    // hash, so reconcileTransaction can tell a tx that can never land from one still pending.
    // Bounded: the oldest of BROADCAST_NONCE_CAP entries is overwritten. Transient — after an
    // upgrade (or a setEvmDerivationPath rebuild) reconcile falls back to "still pending".
    let BROADCAST_NONCE_CAP : Nat = 10_000;
    let broadcastNonces = HashMap.HashMap<Text, { chainId : Nat; nonce : Nat }>(16, Text.equal, Text.hash);
    var broadcastRing : [var Text] = [var];
    var broadcastRingNext : Nat = 0;

    func recordBroadcastNonce(txHash : Text, chainId : Nat, nonce : Nat) {
      let k = Text.toLowercase(txHash);
      if (broadcastNonces.get(k) != null) { broadcastNonces.put(k, { chainId; nonce }); return };
      if (broadcastRing.size() == 0) { broadcastRing := Array.init<Text>(BROADCAST_NONCE_CAP, "") };
      let old = broadcastRing[broadcastRingNext];
      if (old != "") { broadcastNonces.delete(old) };
      broadcastRing[broadcastRingNext] := k;
      broadcastRingNext := (broadcastRingNext + 1) % BROADCAST_NONCE_CAP;
      broadcastNonces.put(k, { chainId; nonce });
    };

    /// 2.22.0: the account nonce this sender signed `txHash` with on `chainId`, if it remembers.
    public func broadcastNonce(chainId : Nat, txHash : Text) : ?Nat {
      switch (broadcastNonces.get(Text.toLowercase(txHash))) {
        case (?e) { if (e.chainId == chainId) { ?e.nonce } else { null } };
        case (null) { null };
      };
    };

    // S10: require multi-provider AGREEMENT on every outbound RPC, so a single compromised
    // or stale provider can't forge a result — e.g. a fake "confirmed" receipt that would
    // mint a paid receipt / credit an escrow. `total = null` queries all configured providers;
    // `min = 2` requires at least two to agree (vs. the prior `null` config, which could act
    // on a single provider's answer for the 2-provider custom chains).
    let RPC_CONFIG : ?EvmRpc.RpcConfig = ?{
      responseSizeEstimate = null;
      responseConsensus = ?#Threshold({ total = null; min = 2 });
    };

    // Ops cycle floor: refuse to BROADCAST a tx the canister can't afford to also CONFIRM.
    // A full settle is ~7 EVM-RPC outcalls (fee + nonce + send + up to 4 receipt polls) plus a
    // tECDSA sign — on the order of 100B cycles. Below this floor sendTransaction returns a
    // PRE-broadcast #err (no funds move; every caller rolls back safely) instead of broadcasting
    // and then freezing mid-confirm — which is exactly what leaves a transfer parked. Top up the
    // canister to clear it. (Surfaced via the example's `health` query cycle balance.)
    let MIN_BROADCAST_CYCLES : Nat = 120_000_000_000;

    /// Get or cache the canister's compressed secp256k1 public key.
    public func getPublicKey() : async [Nat8] {
      switch (cachedPubKey) {
        case (?pk) { pk };
        case (null) {
          let result = await IC.ic.ecdsa_public_key({
            key_id = { name = ecdsaKeyName; curve = #secp256k1 };
            canister_id = null;
            derivation_path = derivationPath;
          });
          let pk = Blob.toArray(result.public_key);
          cachedPubKey := ?pk;
          pk;
        };
      };
    };

    /// Get or derive the canister's EVM address.
    public func getEvmAddress() : async Text {
      switch (cachedEvmAddr) {
        case (?addr) { addr };
        case (null) {
          let pk = await getPublicKey();
          switch (EvmAddress.fromCompressedPublicKey(pk)) {
            // C2: cache ONLY on success — a transient #err must not permanently cache ""
            // (which would poison every later send with the empty/zero sender address).
            case (#ok(a)) { cachedEvmAddr := ?a; a };
            case (#err(_)) { "" };
          };
        };
      };
    };

    /// Send a generic EVM transaction with arbitrary calldata.
    /// Returns the tx hash on success.
    public func sendTransaction(
      chainId : Nat,
      toAddress : Text,
      calldata : [Nat8],
      gasLimit : Nat,
    ) : async { #ok : Text; #err : Text; #maybeSent : { txHash : Text; reason : Text } } {
      // Cycle floor (see MIN_BROADCAST_CYCLES): never broadcast a tx we can't afford to confirm.
      // Pre-broadcast #err => no funds move and callers roll back safely.
      if (Cycles.balance() < MIN_BROADCAST_CYCLES) {
        return #err("Insufficient cycles to safely broadcast and confirm; top up the canister");
      };
      // M9: validate the destination address BEFORE taking the single-flight lock. addressToBytes
      // (used below to build the tx) asserts a 20-byte decode and TRAPS on a malformed address;
      // a trap after `txInProgress := true` (committed at the first await) would leave the lock
      // stuck true and wedge the ENTIRE outbound rail — every close/settle/refund/sweep — until
      // canister upgrade. Fail cleanly here (no lock taken, no funds moved) instead.
      if (EvmUtils.hexToBytes(toAddress).size() != 20) {
        return #err("Invalid destination address (expected a 20-byte / 40-hex-char address): " # toAddress);
      };
      // H-1: Reject concurrent transactions to prevent nonce desync.
      if (txInProgress) {
        return #err(SEND_BUSY);
      };
      txInProgress := true;
      // B2: #err means the tx was definitely NOT broadcast (safe to roll back + retry);
      // #maybeSent means it may have reached a provider's mempool (caller must NOT
      // re-broadcast — the outbound rail has no on-chain replay protection).
      let result : { #ok : Text; #err : Text; #maybeSent : { txHash : Text; reason : Text } } = try {
        let pubKey = await getPublicKey();
        let senderAddr = await getEvmAddress();

        let (evmRpc, services) = switch (EvmRpc.resolveRpc(evmRpcCanister, chainId)) {
          case (?r) { r };
          case (null) {
            txInProgress := false;
            return #err("Unsupported chain ID: " # Nat.toText(chainId));
          };
        };

        // H-2: Always read the PENDING nonce from chain immediately before each
        // send. EvmSender (broadcast) and EvmSigner (client-broadcast) share the
        // same canister EVM address; a long-lived in-memory nonce cache desynced
        // the moment the other path landed a tx, producing stuck/replaced txs.
        // Reading #Pending each time self-heals and accounts for in-flight txs.
        let nonce = switch (
          await (with cycles = EvmRpc.RPC_CYCLES) evmRpc.eth_getTransactionCount(
            services, RPC_CONFIG, { address = senderAddr; block = #Pending },
          )
        ) {
          case (#Consistent(#Ok(n))) { n };
          case (_) {
            txInProgress := false;
            return #err("Failed to get EVM nonce: eth_getTransactionCount did not reach multi-provider consensus. Nothing was broadcast — safe to retry. If it persists, check the EVM-RPC canister's providers/cycles for this chain.");
          };
        };

        // H-3: Get fee data; if unavailable, do NOT broadcast a low-fee tx.
        let (maxFee, priorityFee) = switch (await getFeeData(evmRpc, services)) {
          case (?fd) { fd };
          case (null) {
            txInProgress := false;
            return #err("EVM fee data unavailable — not broadcasting (retry later)");
          };
        };

        // Build unsigned tx
        let txParams : EvmUtils.TxParams = {
          chainId;
          nonce;
          maxPriorityFeePerGas = priorityFee;
          maxFeePerGas = maxFee;
          gasLimit;
          to = EvmUtils.addressToBytes(toAddress);
          value = 0;
          data = calldata;
        };
        let txHash = EvmUtils.unsignedTxHash(txParams);

        // Sign (auto-cycles via ic mops package)
        let signResult = await Call.signWithEcdsa({
          key_id = { name = ecdsaKeyName; curve = #secp256k1 };
          derivation_path = derivationPath;
          message_hash = Blob.fromArray(txHash);
        });
        let sigBytes = Blob.toArray(signResult.signature);
        let r = Array.subArray(sigBytes, 0, 32);
        // EIP-2 low-S: the IC's tECDSA normalizes s today, but only as an implementation
        // detail (the interface spec is silent) — normalize defensively BEFORE parity
        // recovery, so no manual yParity flip is needed.
        let (s, _) = EvmAddress.normalizeS(Array.subArray(sigBytes, 32, 32));

        let yParity = EvmAddress.recoverYParity(txHash, r, s, pubKey);

        // Submit
        let rawTxBytes = EvmUtils.signedRawTx(txParams, r, s, yParity);
        let rawTxHex = EvmUtils.bytesToHex(rawTxBytes);
        // H2/M11: the canonical tx hash is keccak256 of the signed raw tx — derive it
        // LOCALLY so every ambiguous/hashless outcome still yields a POLLABLE hash. A
        // provider that accepts the tx without echoing a hash (#Ok(null)), or a network
        // error / #Inconsistent / #NonceTooHigh after dispatch, must NOT surface an error
        // string in the hash position: callers park the returned value and poll
        // eth_getTransactionReceipt with it, and a message string can never resolve.
        let broadcastTxHash = EvmAddress.toHex(EvmAddress.keccak256(rawTxBytes));
        recordBroadcastNonce(broadcastTxHash, chainId, nonce);

        // B2: isolate the broadcast so a network error AFTER dispatch (which may have
        // reached a provider's mempool) is reported as #maybeSent, not #err.
        let sendResult = try {
          await (with cycles = EvmRpc.RPC_CYCLES) evmRpc.eth_sendRawTransaction(services, RPC_CONFIG, rawTxHex);
        } catch (e) {
          txInProgress := false;
          return #maybeSent({ txHash = broadcastTxHash; reason = "EVM send failed after dispatch (may have broadcast): " # Error.message(e) });
        };
        let outcome = classifySend(sendResult, broadcastTxHash);
        switch (outcome) {
          case (#ok(h)) { if (h != broadcastTxHash) { recordBroadcastNonce(h, chainId, nonce) } };
          case (_) {};
        };
        switch (sendResult) {
          case (#Consistent(#Ok(#InsufficientFunds))) {
            // 2.22.0 (F1): under the 2-of-N threshold a provider that saw a gas top-up may have
            // accepted this tx while the agreeing two refused it. Re-read the pending nonce: if it
            // moved past this tx's nonce, something holds that nonce — treat the tx as maybe sent
            // (confirm, never re-send) rather than letting the caller roll back and send again.
            let moved = try {
              switch (
                await (with cycles = EvmRpc.RPC_CYCLES) evmRpc.eth_getTransactionCount(
                  services, RPC_CONFIG, { address = senderAddr; block = #Pending },
                )
              ) {
                case (#Consistent(#Ok(p))) { p > nonce };
                case (_) { false };
              };
            } catch (_) { false };
            if (moved) {
              #maybeSent({ txHash = broadcastTxHash; reason = "Insufficient ETH for gas was reported, but the account's pending nonce has since moved past this tx's nonce — a provider may have accepted it; confirming instead of re-sending" });
            } else { outcome };
          };
          case (_) { outcome };
        };
      } catch (e) {
        // Exception BEFORE the broadcast (pubkey / nonce / fee / signing) — no tx sent.
        #err("EVM tx failed before broadcast: " # Error.message(e));
      } finally {
        // M9: guarantee the single-flight lock is released on EVERY exit — including a local trap
        // (e.g. an assert), which `catch` does NOT intercept. Without this, one trap after the
        // lock is taken would strand txInProgress = true and wedge the whole outbound rail.
        txInProgress := false;
      };
      result;
    };

    /// Send an ERC-20 `transfer(address,uint256)` transaction.
    public func sendErc20Transfer(
      chainId : Nat,
      tokenAddress : Text,
      recipientAddress : Text,
      amount : Nat,
    ) : async { #ok : Text; #err : Text; #maybeSent : { txHash : Text; reason : Text } } {
      let selector = EvmUtils.functionSelector("transfer(address,uint256)");
      let recipientBytes = EvmUtils.hexToBytes(recipientAddress);
      // L21: a malformed recipient (odd/invalid hex → [], or truncated even-length hex) would be
      // silently zero-extended to address(0) or a different valid address and then signed +
      // broadcast — burning gas (USDC reverts on to==0) or, for a token without a zero-address
      // guard, permanently losing the funds. Reject pre-broadcast. (sendTransaction validates the
      // TOKEN address; the recipient is encoded into calldata HERE, so it needs its own check.)
      if (recipientBytes.size() != 20) {
        return #err("Invalid recipient address (expected a 20-byte / 40-hex-char address): " # recipientAddress);
      };
      // 2.22.0: the ABI encoder truncates to 32 bytes; an amount past uint256 would send a different one.
      if (not EvmUtils.isUint256(amount)) {
        return #err("Amount does not fit uint256; nothing was broadcast");
      };
      let calldata = EvmUtils.abiEncodeFunctionCall(
        selector,
        [
          #static_(EvmUtils.natToBytes(EvmUtils.bytesToNat(recipientBytes), 32)),
          #static_(EvmUtils.abiEncodeUint256(amount)),
        ],
      );
      // 2.22.0: 100_000, was 65_000 — see EvmUtils.ERC20_TRANSFER_GAS.
      await sendTransaction(chainId, tokenAddress, calldata, EvmUtils.ERC20_TRANSFER_GAS);
    };

    /// Send an ERC-20 transfer AND confirm it mined (status==1) before returning a
    /// terminal result — the OUTBOUND analogue of executeTransferWithAuthorization's
    /// H-1 confirmation. Returns:
    ///   #confirmed(hash) — mined, status==1: safe to finalize.
    ///   #reverted(hash)  — mined, status==0: no funds moved; safe to roll back.
    ///   #pending(hash)   — broadcast but not confirmed (incl. confirmation RPC
    ///                      unavailable): it MAY have landed, so callers MUST NOT
    ///                      finalize AND MUST NOT auto-retry by re-calling this (a
    ///                      re-broadcast signs a fresh nonce and double-pays) — re-poll
    ///                      confirmTransaction on the hash, or recover manually.
    ///   #err(msg)        — failed BEFORE broadcast (no tx sent): safe to roll back.
    public func sendErc20TransferConfirmed(
      chainId : Nat,
      tokenAddress : Text,
      recipientAddress : Text,
      amount : Nat,
      maxPolls : Nat,
    ) : async { #confirmed : Text; #reverted : Text; #pending : Text; #err : Text } {
      switch (await sendErc20Transfer(chainId, tokenAddress, recipientAddress, amount)) {
        case (#err(msg)) { #err(msg) }; // definitely not broadcast — safe to roll back
        // H2: may have broadcast — never re-send. 2.22.0 (F1): poll the locally derived hash with
        // the same budget before parking, so a tx that did land (a NonceTooLow for this very tx,
        // say) finalizes now instead of waiting for a manual reconcile.
        case (#maybeSent(m)) {
          switch (await confirmTransaction(chainId, m.txHash, maxPolls)) {
            case (#confirmed) { #confirmed(m.txHash) };
            case (#reverted) { #reverted(m.txHash) };
            case (_) { #pending(m.txHash) };
          };
        };
        case (#ok(txHash)) {
          switch (await confirmTransaction(chainId, txHash, maxPolls)) {
            case (#confirmed) { #confirmed(txHash) };
            case (#reverted) { #reverted(txHash) };
            case (#pending) { #pending(txHash) };
            // Confirmation RPC unavailable, but the tx WAS broadcast — treat as pending
            // (not failed), mirroring the inbound path (Gateway.settle #err arm).
            case (#err(_)) { #pending(txHash) };
          };
        };
      };
    };

    /// Execute an EIP-3009 `transferWithAuthorization` on a USDC contract.
    /// The canister acts as its own facilitator — it pays gas to execute
    /// the payer's signed authorization.
    public func executeTransferWithAuthorization(
      chainId : Nat,
      tokenAddress : Text,
      from : [Nat8],       // 20 bytes
      to : [Nat8],         // 20 bytes
      value : Nat,
      validAfter : Nat,
      validBefore : Nat,
      authNonce : [Nat8],  // 32 bytes
      v : Nat8,
      r : [Nat8],          // 32 bytes
      s : [Nat8],          // 32 bytes
    ) : async { #ok : Text; #err : Text; #maybeSent : { txHash : Text; reason : Text } } {
      // 2.22.0: refuse fields the calldata encoder would truncate (or trap on) — nothing is sent.
      if (not EvmUtils.eip3009FieldsFit(value, validAfter, validBefore, authNonce) or from.size() != 20 or to.size() != 20 or r.size() != 32 or s.size() != 32) {
        return #err("EIP-3009 authorization fields do not fit their on-chain types; nothing was broadcast");
      };
      // Build calldata via the pure module-level encoder, which denormalizes v (0/1 → 27/28)
      // for the on-chain ecrecover. Kept out of this async fn so it is unit-testable.
      let calldata = buildTransferWithAuthorizationCalldata(
        from,
        to,
        value,
        validAfter,
        validBefore,
        authNonce,
        v,
        r,
        s,
      );
      // transferWithAuthorization uses more gas than a simple transfer (~80k).
      // B2 (G5/G6): SURFACE #maybeSent (with its tx hash), do not collapse it to #err. The inbound
      // EIP-3009 path is replay-protected on-chain (the authorization's token nonce is single-use),
      // so an ambiguous broadcast cannot double-pay — but it MAY still mine, so the caller must keep
      // the tx hash to poll/reconcile it rather than stranding a hash-less #settlementFailed. Callers
      // (Gateway.settle, Sessions.openEvmSession) route the hash into confirmTransaction.
      switch (await sendTransaction(chainId, tokenAddress, calldata, 120_000)) {
        case (#ok(h)) { #ok(h) };
        case (#err(e)) { #err(e) };
        case (#maybeSent(m)) { #maybeSent(m) };
      };
    };

    // latestBaseFee + feeFromBase are pure functions defined at module scope (above
    // the class) so they are unit-testable without constructing an EvmSender.

    // H-3: Returns null when fee data is unavailable instead of fabricating a
    // tiny (~0.1 gwei) fee. The previous fallback produced transactions that are
    // unmineable on mainnet/busy L2s yet were still broadcast, jamming the nonce
    // pipeline. Callers must NOT broadcast on null — they return an error so the
    // operation can be retried with fresh fee data.
    //
    // S16: fee data is a NON-security gas estimate (the transfer amount + recipient
    // are bound by the signed tx and enforced on-chain), so unlike the nonce /
    // sendRawTransaction paths it does NOT require strict multi-provider agreement.
    // eth_feeHistory(#Latest) returns a per-block base fee, so providers at slightly
    // different chain tips routinely disagree → #Inconsistent. Rather than park the
    // CLOSE on that (the prior behaviour), take the ROBUST (lower-median) base fee across providers
    // that returned data (SEC-2: NOT the max — one hostile/outlier provider reporting an extreme fee
    // would otherwise make the gas reservation unpayable and grief-park every close). Still return
    // null only when NO provider produced a base fee — preserving the genuine-unavailable retry path.
    func getFeeData(evmRpc : EvmRpc.EvmRpcCanister, services : EvmRpc.RpcServices) : async ?(Nat, Nat) {
      try {
        let result = await (with cycles = EvmRpc.RPC_CYCLES) evmRpc.eth_feeHistory(
          services, RPC_CONFIG,
          { blockCount = 1; newestBlock = #Latest; rewardPercentiles = null },
        );
        switch (result) {
          case (#Consistent(#Ok(history))) {
            // L20/H-3: return null (do NOT broadcast) when NO base fee is available, matching the
            // #Inconsistent arm below. The old fabricated 1-gwei fallback broadcast an underpriced,
            // unmineable tx that jams the #Pending-nonce pipeline (no fee-bump mechanism exists) —
            // the exact H-3 failure this function's null-on-unavailable contract is meant to avoid.
            switch (latestBaseFee(history)) {
              case (?b) { ?feeFromBase(b) };
              case (null) { null };
            };
          };
          case (#Inconsistent(results)) {
            // SEC-2: collect every provider's base fee, then take the ROBUST (lower-median) one via
            // robustBaseFee — a single outlier (hostile, or just at a far chain tip) can't drive the
            // gas reservation to an unpayable value and grief-park the close.
            let buf = Buffer.Buffer<Nat>(results.size());
            for ((_, r) in results.values()) {
              switch (r) {
                case (#Ok(history)) {
                  switch (latestBaseFee(history)) { case (?b) { buf.add(b) }; case null {} };
                };
                case (#Err(_)) {}; // this provider errored — skip
              };
            };
            switch (robustBaseFee(Buffer.toArray(buf))) {
              case (?b) { ?feeFromBase(b) };
              case null { null }; // every provider errored / had no data
            };
          };
          // #Consistent(#Err _): all providers agree fee data is unavailable.
          case (_) { null };
        };
      } catch (_) {
        null;
      };
    };

    // H-1: Poll the transaction receipt up to `maxPolls` times to confirm the tx
    // mined successfully. On IC each inter-canister round-trip takes real
    // wall-clock time, so a few polls span ~10-20s — enough for an L2 block.
    // Returns #confirmed on status==1, #reverted on status==0, #pending if not
    // yet mined within the budget, #err on RPC failure.
    /// Poll the tx receipt up to `maxPolls` times: #confirmed on a mined status==1, #reverted on
    /// status==0, #pending if not yet mined within the budget, #err on an RPC failure.
    public func confirmTransaction(
      chainId : Nat,
      txHash : Text,
      maxPolls : Nat,
    ) : async { #confirmed; #reverted; #pending; #err : Text } {
      let (evmRpc, services) = switch (EvmRpc.resolveRpc(evmRpcCanister, chainId)) {
        case (?r) { r };
        case (null) { return #err("Unsupported chain ID: " # Nat.toText(chainId)) };
      };
      var attempts = 0;
      label poll while (attempts < maxPolls) {
        attempts += 1;
        let result = try {
          await (with cycles = EvmRpc.RPC_CYCLES) evmRpc.eth_getTransactionReceipt(services, RPC_CONFIG, txHash);
        } catch (_) { return #err("Receipt query failed — transaction status unknown (it may still mine). Transient RPC failure: re-poll confirmTransaction with the same tx hash; never re-broadcast on this outcome.") };
        switch (result) {
          case (#Consistent(#Ok(?receipt))) {
            switch (receipt.status) {
              case (?1) { return #confirmed };
              case (?0) { return #reverted };
              // A receipt with NO status field is NOT proof of success — do not
              // mint a "paid" receipt / open a funded session on it. All EIP-1559
              // chains we support set status; keep polling and ultimately return
              // #pending (caller must not deliver value on #pending).
              case (_) { /* missing status — keep polling, do not confirm */ };
            };
          };
          case (#Consistent(#Ok(null))) { /* not yet mined — keep polling */ };
          case (_) { /* transient inconsistency — keep polling */ };
        };
      };
      #pending;
    };

    /// 2.22.0 (F1): confirm-only reconcile of a tx this sender broadcast. As confirmTransaction,
    /// plus #dropped: no receipt, and the account's mined-transaction count (#Latest) has passed
    /// the nonce the tx was signed with — another transaction took that nonce, so this one can
    /// never land and moved no funds. Checked in that order and the receipt polled once more after
    /// the count, so a tx mined in between is not reported dropped. A lagging provider pair can
    /// still answer "no receipt" for a mined tx, so callers REPORT #dropped and leave the decision
    /// to an operator. Without a remembered nonce (another instance's tx, or after an upgrade) the
    /// answer stays #pending. Never broadcasts.
    public func reconcileTransaction(
      chainId : Nat,
      txHash : Text,
      maxPolls : Nat,
    ) : async { #confirmed; #reverted; #pending; #dropped : Text; #err : Text } {
      switch (await confirmTransaction(chainId, txHash, maxPolls)) {
        case (#confirmed) { #confirmed };
        case (#reverted) { #reverted };
        case (#err(e)) { #err(e) };
        case (#pending) {
          let n = switch (broadcastNonce(chainId, txHash)) { case (?n) { n }; case (null) { return #pending } };
          let (evmRpc, services) = switch (EvmRpc.resolveRpc(evmRpcCanister, chainId)) {
            case (?r) { r };
            case (null) { return #pending };
          };
          let latest = try {
            switch (
              await (with cycles = EvmRpc.RPC_CYCLES) evmRpc.eth_getTransactionCount(
                services, RPC_CONFIG, { address = await getEvmAddress(); block = #Latest },
              )
            ) {
              case (#Consistent(#Ok(c))) { c };
              case (_) { return #pending };
            };
          } catch (_) { return #pending };
          if (not txNonceConsumed(n, latest)) { return #pending };
          switch (await confirmTransaction(chainId, txHash, 1)) {
            case (#confirmed) { #confirmed };
            case (#reverted) { #reverted };
            case (#err(e)) { #err(e) };
            case (#pending) {
              #dropped("no receipt, and the account has mined " # Nat.toText(latest) # " transactions — nonce " # Nat.toText(n) # " was used by another transaction, so this one can never land");
            };
          };
        };
      };
    };

    /// 2.22.0 (E7): read the token's EIP-3009 `authorizationState(authorizer, nonce)` through the
    /// EVM-RPC canister (eth_call at #Latest, the same 2-of-N agreement as every other read).
    /// #used means the authorization was executed by SOME transaction or cancelled by the payer.
    /// Never broadcasts.
    public func authorizationState(
      chainId : Nat,
      tokenAddress : Text,
      authorizer : [Nat8],
      authNonce : [Nat8],
    ) : async AuthorizationState {
      if (authorizer.size() != 20 or authNonce.size() != 32 or EvmUtils.hexToBytes(tokenAddress).size() != 20) {
        return #unknown("malformed authorizer, nonce or token address");
      };
      let (evmRpc, services) = switch (EvmRpc.resolveRpc(evmRpcCanister, chainId)) {
        case (?r) { r };
        case (null) { return #unknown("Unsupported chain ID: " # Nat.toText(chainId)) };
      };
      let call : EvmRpc.CallArgs = {
        transaction = {
          type_ = null; nonce = null; to = ?tokenAddress; from = null; gas = null; value = null;
          input = ?EvmUtils.bytesToHex(buildAuthorizationStateCalldata(authorizer, authNonce));
          gasPrice = null; maxPriorityFeePerGas = null; maxFeePerGas = null; maxFeePerBlobGas = null;
          accessList = null; blobVersionedHashes = null; blobs = null; chainId = null;
        };
        block = ?#Latest;
      };
      try {
        classifyAuthorizationState(await (with cycles = EvmRpc.RPC_CYCLES) evmRpc.eth_call(services, RPC_CONFIG, call));
      } catch (e) { #unknown("authorizationState call failed: " # Error.message(e)) };
    };
  };
  // ── Construction ──
  //
  // Same shape as EvmSigner's (2.15.0): Motoko has no constructor overloading (M0051) and a
  // constructor cannot return a Result (M0134), so both forms are factories over one class.
  // `EvmSender` stays a TYPE and a two-argument constructor, so every pre-2.16.0 caller
  // compiles unchanged.

  /// The sender type. Unchanged name so existing annotations keep resolving.
  public type EvmSender = Sender;

  /// Sender on the canister's own root key — the pre-2.16.0 behaviour, byte for byte.
  /// The empty path is a DEFAULT, not a decision.
  public func EvmSender(ecdsaKeyName : Text, evmRpcCanister : ?Text) : Sender =
    Sender(ecdsaKeyName, evmRpcCanister, []);

  /// Sender on an explicit derivation path, validated.
  ///
  /// Bounds are SchnorrSigner's own `validateDerivationPath` — reused, not restated, so the
  /// signers cannot drift apart on what a valid path is. Returns `#err`; never traps.
  ///
  /// INVARIANT: this path must equal the path of the `EvmSigner` that signs for the same
  /// address and the `Gateway` recipient that receives on it. Settling from one path while
  /// funds arrive at another spends from an address nothing funds.
  public func EvmSenderAt(
    ecdsaKeyName : Text,
    evmRpcCanister : ?Text,
    derivationPath : [Blob],
  ) : { #ok : Sender; #err : Text } {
    switch (SchnorrSigner.validateDerivationPath(derivationPath)) {
      case (#err(e)) { #err(e) };
      case (#ok) { #ok(Sender(ecdsaKeyName, evmRpcCanister, derivationPath)) };
    };
  };
};
