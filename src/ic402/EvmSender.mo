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
import Time "mo:base/Time";
import Int "mo:base/Int";
import IC "mo:ic";
import Call "mo:ic/Call";
import SchnorrSigner "SchnorrSigner";

module {

  /// The outcome of an outbound send. #err: the tx was definitely NOT broadcast (safe to roll
  /// back and retry). #maybeSent: it may be on chain; the caller must confirm-poll `txHash`, never
  /// re-broadcast. #ok: accepted, with its hash.
  public type SendOutcome = { #ok : Text; #err : Text; #maybeSent : { txHash : Text; reason : Text } };

  /// 2.23.2: the start of the error a broadcast gets when the canister's EVM address cannot pay
  /// the gas (classifySend). sendTransaction then stops sends on that chain (GasStops).
  public let INSUFFICIENT_GAS : Text = "Insufficient ETH for gas";

  /// 2.23.2: true when `err` is, or contains (a caller may prefix it), the error of a broadcast the
  /// canister could not pay gas for.
  public func isInsufficientGas(err : Text) : Bool { Text.contains(err, #text INSUFFICIENT_GAS) };

  // The words before the signed tx's hash in classifySend's INSUFFICIENT_GAS text.
  let SIGNED_TX_MARKER : Text = "refused signed tx ";

  /// The hash of the signed tx a gas refusal names (classifySend's INSUFFICIENT_GAS text, which a
  /// caller may prefix), or null for any other text. Two providers refused that tx, but under the
  /// 2-of-3 threshold a third may have accepted it, so an outbound caller treats it as maybe sent:
  /// parked with this hash for a confirm-only reconcile, never retried.
  public func gasRefusedTxHash(err : Text) : ?Text {
    if (not isInsufficientGas(err)) return null;
    let parts = Text.split(err, #text SIGNED_TX_MARKER);
    ignore parts.next();
    let rest = switch (parts.next()) { case (?r) { r }; case (null) { return null } };
    var hash = "";
    label scan for (c in rest.chars()) {
      if (hash.size() == 66) break scan;
      hash #= Text.fromChar(c);
    };
    if (Text.startsWith(hash, #text "0x") and EvmUtils.hexToBytes(hash).size() == 32) { ?hash } else { null };
  };

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
      case (#Consistent(#Ok(#InsufficientFunds))) {
        #err(INSUFFICIENT_GAS # " — the canister's derived EVM address pays gas for broadcasts. Fund it with the chain's native token (getEvmAddress()/getEvmRecipient() shows the address) and retry; nothing was broadcast. The agreeing providers " # SIGNED_TX_MARKER # broadcastTxHash # "; one that already saw a top-up could have accepted it, so check that hash is not on chain before sending the same transfer again by hand.");
      };
      // Raised by the EVM-RPC canister before any provider was called.
      case (#Consistent(#Err(#ProviderError(e)))) { #err("RPC error before sending: " # EvmRpc.rpcErrorToText(#ProviderError(e))) };
      case (#Consistent(#Err(#ValidationError(e)))) { #err("RPC error before sending: " # EvmRpc.rpcErrorToText(#ValidationError(e))) };
      // A node error or an outcall error: the tx may have reached a provider.
      case (#Consistent(#Err(e))) { #maybeSent({ txHash = broadcastTxHash; reason = "RPC error after dispatch (may have broadcast): " # EvmRpc.rpcErrorToText(e) }) };
      // Providers disagree — one may have accepted the tx into its mempool.
      case (#Inconsistent(_)) { #maybeSent({ txHash = broadcastTxHash; reason = "Inconsistent RPC responses (a provider may have accepted the tx)" }) };
    };
  };

  /// 2.23.2: whether a send's result reports the canister short of gas: an InsufficientFunds
  /// status, or a node's JSON-RPC error worded as one (geth/Erigon "insufficient funds",
  /// Nethermind "InsufficientFunds", Besu "Upfront cost exceeds account balance"; an HTTP error
  /// body is not read), agreed, or from at least one provider when the providers disagree and none
  /// of them accepted the tx (an accepted tx, or a nonce too low or too high, which may mean it is
  /// in). sendTransaction then stops the chain (GasStops); the send's own outcome is unchanged
  /// (classifySend). A stop sends nothing, so weak evidence is enough; while it lasts, sends on the
  /// chain wait (a timer close and the job sweep retry them, see sendCanWait).
  public func gasShortageReported(r : EvmRpc.MultiSendRawTransactionResult) : Bool {
    func says(x : EvmRpc.SendRawTransactionResult) : Bool {
      switch (x) {
        case (#Ok(#InsufficientFunds)) { true };
        case (#Err(#JsonRpcError({ message }))) {
          let m = Text.toLowercase(message);
          Text.contains(m, #text "insufficient funds") or Text.contains(m, #text "insufficientfunds") or Text.contains(m, #text "upfront cost exceeds");
        };
        case (_) { false };
      };
    };
    switch (r) {
      case (#Consistent(x)) { says(x) };
      case (#Inconsistent(results)) {
        var reported = false;
        for ((_, x) in results.vals()) {
          switch (x) { case (#Ok(#Ok(_)) or #Ok(#NonceTooLow) or #Ok(#NonceTooHigh)) { return false }; case (_) {} };
          if (says(x)) { reported := true };
        };
        reported;
      };
    };
  };

  /// 2.22.0: the single-flight lock's refusal, verbatim. Named so a caller can tell this
  /// transient, nothing-broadcast refusal from the other pre-broadcast errors (`isSendBusy`).
  public let SEND_BUSY : Text = "Another outbound EVM transaction is in progress — sends are serialized to keep the nonce consistent. Nothing was broadcast; retry in a few seconds.";

  /// 2.22.0: true when a send's #err is the busy single-flight lock (SEND_BUSY), which clears by
  /// itself once the send holding the lock returns.
  public func isSendBusy(err : Text) : Bool { err == SEND_BUSY or err == INBOUND_SEND_BUSY };

  /// 2.22.0 (F1): whether a tx signed with account nonce `txNonce` can still land, given the
  /// account's mined-transaction count `latestNonce` (eth_getTransactionCount at #Latest). Once
  /// the count passes the tx's nonce, a transaction with that nonce has been mined; if no receipt
  /// exists for this tx's hash, it was another one, and this tx can never be included.
  public func txNonceConsumed(txNonce : Nat, latestNonce : Nat) : Bool { latestNonce > txNonce };

  /// 2.22.0 (F1, round 2): the verdict of reconcileTransaction's LAST receipt read, taken after
  /// the account's count passed the tx's nonce. Only an explicit, agreed "no receipt"
  /// (#Consistent(#Ok(null))) is #dropped. Providers that disagree, an RPC error, or a receipt
  /// without a status are NO answer — #pending — because a mined tx read during provider lag
  /// looks exactly like that, and reporting it dropped invites a second payout.
  public func finalReceiptVerdict(r : EvmRpc.MultiGetTransactionReceiptResult) : { #confirmed; #reverted; #pending; #dropped } {
    switch (r) {
      case (#Consistent(#Ok(null))) { #dropped };
      case (#Consistent(#Ok(?receipt))) {
        switch (receipt.status) {
          case (?1) { #confirmed };
          case (?0) { #reverted };
          case (_) { #pending };
        };
      };
      case (_) { #pending };
    };
  };

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

  // ── Simulate before signing (2.23.1) ──
  //
  // The canister pays for the signature, the RPC reads and the gas of every inbound transfer it
  // broadcasts, and an EIP-3009 authorization from a wallet holding nothing costs its signer
  // nothing. Before 2.23.1 such an authorization passed every check (they are all off-chain) and
  // was signed and sent, to revert on chain: about one threshold signature of cycles per try, with
  // the single-flight send lock held while it ran. executeTransferWithAuthorization now simulates
  // the exact call first and signs only what the chain says will succeed.

  /// 2.23.1: what a simulation (eth_call) of a transferWithAuthorization says, before anything is
  /// signed. #ok only when the providers agree the call succeeds. #reverted when they agree it
  /// reverts, or when they disagree but at least two report a revert and none a success (their
  /// messages may differ; the third may have failed). #unknown otherwise.
  public type SimulationVerdict = { #ok; #reverted : Text; #unknown : Text };

  /// 2.23.1: true for a JSON-RPC error reporting an EVM revert — geth's code 3, or any message
  /// naming one ("execution reverted: …"). Provider and outcall failures are not reverts.
  public func isRevertError(e : EvmRpc.RpcError) : Bool {
    switch (e) {
      case (#JsonRpcError(j)) { j.code == 3 or Text.contains(Text.toLowercase(j.message), #text "revert") };
      case (_) { false };
    };
  };

  /// 2.23.1: classify the simulation's eth_call. Only an agreed success lets the send go ahead.
  public func classifySimulation(r : EvmRpc.MultiCallResult) : SimulationVerdict {
    switch (r) {
      case (#Consistent(#Ok(_))) { #ok };
      case (#Consistent(#Err(e))) {
        if (isRevertError(e)) { #reverted(EvmRpc.rpcErrorToText(e)) } else { #unknown(EvmRpc.rpcErrorToText(e)) };
      };
      case (#Inconsistent(results)) {
        // The sender asks for 2-of-N agreement; two reverts and no success is that agreement on a
        // revert, whatever the rest answered (a rate limit, an outcall error).
        var revert : ?Text = null; // the first revert seen
        var reverts = 0;
        var successes = 0;
        for ((_, cr) in results.values()) {
          switch (cr) {
            case (#Err(e)) {
              if (isRevertError(e)) {
                reverts += 1;
                if (revert == null) { revert := ?EvmRpc.rpcErrorToText(e) };
              };
            };
            case (#Ok(_)) { successes += 1 };
          };
        };
        switch (revert) {
          case (?m) { if (reverts >= 2 and successes == 0) { return #reverted(m) } };
          case (null) {};
        };
        #unknown("providers disagree on the simulation");
      };
    };
  };

  /// 2.23.1: the refusal when the simulation reverts. Nothing was signed or sent.
  public func simulationRevertedText(detail : Text) : Text {
    "The token refuses this transfer: a simulation before signing reverted (" # detail # "). Usual causes: the payer's balance is below the amount, the authorization was already used or cancelled, the token is paused, or the payer is blocked. Nothing was signed or sent; fix the cause before paying again.";
  };

  /// 2.23.1: the refusal when the simulation gives no agreed answer. Nothing was signed or sent.
  public func simulationUnknownText(detail : Text) : Text {
    "Could not check this transfer with the chain before signing (" # detail # "). Nothing was signed or sent; retry this same payment shortly.";
  };

  /// 2.23.1: the refusal for a simulation `verdict` (null for #ok). The simulation runs at the
  /// chain's latest block, which trails the clock: a revert while the authorization became valid
  /// less than RECENTLY_VALID_SECONDS ago may only mean that block predates `validAfter`, so it is
  /// answered as "could not check", which invites the same payment again.
  public func simulationRefusal(verdict : SimulationVerdict, validAfter : Nat, nowSeconds : Nat) : ?Text {
    switch (verdict) {
      case (#ok) { null };
      case (#reverted(d)) {
        if (validAfter + RECENTLY_VALID_SECONDS > nowSeconds) {
          ?simulationUnknownText("it reverted, but the authorization became valid only moments ago and the chain's latest block may predate it: " # d);
        } else { ?simulationRevertedText(d) };
      };
      case (#unknown(d)) { ?simulationUnknownText(d) };
    };
  };
  public let RECENTLY_VALID_SECONDS : Nat = 60;

  /// 2.23.1: the least time an inbound authorization must still be valid for when the canister
  /// takes it. The simulation runs at the latest block, and the nonce and fee reads, the signature,
  /// the send and inclusion follow it; an authorization that expires in that gap passes the
  /// simulation and reverts on chain at the canister's cost. Checked by Gateway.settle,
  /// Gateway.verifyPayment, the session-open deposit and executeTransferWithAuthorization.
  public let MIN_VALIDITY_SECONDS : Nat = 120;

  /// 2.23.1: true when `validBefore` leaves less than MIN_VALIDITY_SECONDS (an expired one too).
  public func expiresTooSoon(validBefore : Nat, nowSeconds : Nat) : Bool {
    validBefore < nowSeconds + MIN_VALIDITY_SECONDS;
  };

  /// 2.23.1: the refusal for an authorization that expires too soon. Nothing was signed or sent.
  public let EXPIRES_TOO_SOON : Text = "Authorization expired, or expires too soon: it must stay valid for at least 120 more seconds, so it cannot expire between the check and its inclusion on chain. Nothing was signed or sent; sign a new one with a later validBefore.";

  /// 2.23.1: the refusal when the same payer already has a transfer in flight (see PayerGuard).
  /// Contains "retry this same payment", which @ic402/client reads as transient (not funds-moved).
  public let PAYER_BUSY : Text = "Another payment from this payer, on this chain and token, is still settling, so this one was not sent — retry this same payment in a few seconds, once that one returns.";

  /// 2.23.1: the refusal while a payer is cooling down (see PayerGuard.coolDown). Final for now:
  /// it does not invite a retry.
  public func payerCoolingText(untilSeconds : Nat) : Text {
    "This payer's last transfer, sent by this canister, reverted on chain after passing the check, or has not confirmed yet. Payments from this payer, on this chain and token, are refused until " # Nat.toText(untilSeconds) # " (Unix seconds), so it cannot make the canister pay for failing transfers. Nothing of this one was signed or sent.";
  };

  /// 2.23.1: how long a payer is refused after its sent transfer reverted (PayerGuard.coolDown).
  public let REVERT_COOLDOWN_SECONDS : Nat = 3_600;

  /// 2.23.1: how long a payer is refused after its sent transfer did not confirm within the
  /// confirmation polls (#settlementPending), long enough for it to land or drop. A revert seen in
  /// that time is not cooled (nothing watches), so this is also the bound on that case.
  public let UNCONFIRMED_HOLD_SECONDS : Nat = 300;

  /// 2.23.1: the inbound refusal when the single-flight send lock is held. Transient.
  public let INBOUND_SEND_BUSY : Text = "Another outbound EVM transaction is in progress (sends are serialized to keep the nonce consistent), so this payment was not sent — retry this same payment in a few seconds.";

  /// 2.23.1: a pre-broadcast send failure that clears by itself: the send lock, a nonce or fee read
  /// that failed or was rejected, or another failure before the broadcast (signing). An inbound
  /// payment refused for one is asked to retry the same payment. Each prefix is the start of the
  /// error sendTransaction builds (the constants below are used there too).
  public func transientSendError(err : Text) : Bool {
    isSendBusy(err) or Text.startsWith(err, #text NONCE_READ_FAILED) or Text.startsWith(err, #text FEE_DATA_UNAVAILABLE) or Text.startsWith(err, #text FAILED_BEFORE_BROADCAST);
  };
  public let NONCE_READ_FAILED : Text = "Failed to get EVM nonce";
  public let FEE_DATA_UNAVAILABLE : Text = "EVM fee data unavailable";
  public let FAILED_BEFORE_BROADCAST : Text = "EVM tx failed before broadcast";

  /// 2.23.1: the refusal while the simulation budget is spent (see SimulationBudget). Transient:
  /// it contains "retry this same payment".
  public let SIMULATION_BUSY : Text = "The canister's budget for checking payments against the chain is spent for now (too many checks lately led to no send), so this one was not checked, signed or sent — retry this same payment in a minute.";

  /// 2.23.1: the refusal below MIN_INBOUND_CYCLES.
  public let LOW_INBOUND_CYCLES : Text = "The canister's cycles are below its reserve for new inbound payments (500B), which it keeps for closes and refunds. Nothing was signed or sent; the operator must top up the canister.";

  /// 2.23.2: how long sends on a chain are refused after a broadcast there found the canister
  /// unable to pay gas (GasStops).
  public let GAS_STOP_SECONDS : Nat = 600;

  /// 2.23.2: the start of every gas-stop refusal (gasStopText). Stable: match on it, or use
  /// `isGasStopped`, rather than on the rest of the wording.
  public let GAS_STOP_PREFIX : Text = "This canister cannot pay gas on chain ";

  /// 2.23.2: the refusal while a chain's gas stop is in force (GasStops). Final for now: the
  /// operator has to fund the address, so it does not invite a retry.
  public func gasStopText(chainId : Nat, untilSeconds : Nat) : Text {
    GAS_STOP_PREFIX # Nat.toText(chainId) # " right now: a transaction it broadcast there failed because its EVM address holds too little of the chain's native token. Payments and sends on this chain are refused until " # Nat.toText(untilSeconds) # " (Unix seconds), or until the operator funds that address and lifts the stop. Nothing of this was signed or sent.";
  };

  /// 2.23.2: true when `err` is, or contains (a caller may prefix it), a gas-stop refusal.
  public func isGasStopped(err : Text) : Bool { Text.contains(err, #text GAS_STOP_PREFIX) };

  /// 2.23.2: the reason of a send whose broadcast was refused for lack of gas but whose account
  /// nonce then moved (it may have been accepted: #maybeSent). Worded without INSUFFICIENT_GAS, so
  /// nothing reads it as a send that failed before broadcast.
  public let GAS_REFUSAL_NONCE_MOVED : Text = "The providers reported too little ETH for gas, but the account's pending nonce has since moved past this tx's nonce — a provider may have accepted it; confirming instead of re-sending";

  /// 2.23.2: a send's raw #err (as sendTransaction returned it, unprefixed) that was refused before
  /// anything was signed and clears without its caller: the busy send lock (seconds), a gas stop
  /// (until the operator funds the address, or 10 minutes), or a stopped sender (SENDS_STOPPED_PREFIX,
  /// until an upgrade). A timer close reopens the session for
  /// the next tick (Sessions.reopenAfterUnsentLeg), and the job sweep retries the payout uncounted,
  /// instead of parking or counting it. Not the failure that set the stop ("Insufficient ETH for
  /// gas"): that tx was signed, and a provider that already saw a top-up may have accepted it, so
  /// a close leg or a job payout parks it with its hash (`gasRefusedTxHash`) for a confirm-only
  /// reconcile. Matched as a prefix, so text a caller controls (an address quoted in an error)
  /// cannot pass for it.
  public func sendCanWait(err : Text) : Bool {
    isSendBusy(err) or Text.startsWith(err, #text GAS_STOP_PREFIX) or Text.startsWith(err, #text SENDS_STOPPED_PREFIX);
  };

  /// The start of every refusal from a sender whose sends are stopped (Sender.stopSends): its
  /// gateway's recipient is not the address it signs from. Like a gas stop, nothing was signed and
  /// it clears without the caller (here, by an upgrade), so a timer close and the job sweep wait.
  public let SENDS_STOPPED_PREFIX : Text = "EVM sends are stopped, nothing was signed or sent: ";

  /// 2.23.2: the chains where a broadcast recently failed because the canister's EVM address could
  /// not pay the gas. Every send signs before the broadcast can tell, and the simulation before an
  /// inbound transfer runs without a gas price, so on a chain the canister holds no native token on:
  /// - every payment from a wallet holding the token passed the simulation, was signed (~26B cycles
  ///   with key_1) and failed at the broadcast; nothing moved, so the wallet could repeat it, held
  ///   back only by the simulation budget;
  /// - a session payer's close failed before broadcast and reopened the session, so the payer could
  ///   close again, each time signing.
  /// sendTransaction sets a stop when a broadcast reports the canister short of gas
  /// (gasShortageReported; for an agreed InsufficientFunds, unless the account's pending nonce is
  /// then seen to have moved). While it is in force every send on that chain is refused before
  /// signing (a pre-broadcast #err, which every caller handles as "nothing sent"), and an inbound
  /// transfer before its simulation. A chain without gas costs one signature per `seconds`. A stop
  /// is never shortened by a later one. One entry per chain a broadcast reached. Transient: an
  /// upgrade forgets it.
  public class GasStops(seconds : Nat) {
    var stops : [(Nat, Nat)] = []; // (chainId, until), in Unix seconds

    /// Stop sends on `chainId` from `nowSeconds`; an existing, later end is kept.
    public func stop(chainId : Nat, nowSeconds : Nat) {
      var until = nowSeconds + seconds;
      for ((c, u) in stops.vals()) { if (c == chainId and u > until) { until := u } };
      stops := Array.append(Array.filter<(Nat, Nat)>(stops, func((c, _) : (Nat, Nat)) : Bool { c != chainId }), [(chainId, until)]);
    };

    /// The end of `chainId`'s stop when it is in force at `nowSeconds`.
    public func stoppedUntil(chainId : Nat, nowSeconds : Nat) : ?Nat {
      for ((c, u) in stops.vals()) { if (c == chainId and nowSeconds < u) { return ?u } };
      null;
    };

    /// Lift `chainId`'s stop (an operator's call, once the address is funded). True when one was
    /// in force.
    public func lift(chainId : Nat, nowSeconds : Nat) : Bool {
      let was = stoppedUntil(chainId, nowSeconds) != null;
      stops := Array.filter<(Nat, Nat)>(stops, func((c, _) : (Nat, Nat)) : Bool { c != chainId });
      was;
    };

    /// Number of chains remembered (ended stops included until the chain is stopped or lifted again).
    public func size() : Nat { stops.size() };
  };

  /// 2.23.1: the payers with an inbound EIP-3009 transfer in flight on this sender — at most one per
  /// (chainId, token, from) — and the payers cooling down.
  ///
  /// In flight: the simulation before signing reads the payer's balance at the latest block, so
  /// authorizations from one wallet funded once would all pass it while the first is unconfirmed,
  /// and all but one revert at the canister's cost. Holding one slot per payer from before the
  /// simulation until the confirmation resolves makes the next one wait, so its simulation sees the
  /// first transfer's effect. Gateway.settle and the session-open deposit claim a slot after the
  /// signature verifies (only the holder of `from`'s key can occupy it) and release it however the
  /// call returns (`finally`, which also runs on a trap after an await). A slot is released when its
  /// call returns, even when the transfer is still unconfirmed then (#settlementPending): the next
  /// payment's simulation may not see it yet. No expiry, like the send lock: a call that never
  /// returns would hold both.
  ///
  /// Cooling down: a simulation cannot see everything. The payer can move its funds or cancel the
  /// authorization after the check, or (a payer with code, e.g. an EIP-7702 delegate) answer the
  /// simulation differently from the real transaction. All of these end with the sent transfer
  /// reverting. Almost always that is the payer's doing (a third party cannot cancel or spend for
  /// it); a token paused, or the canister blocked, between the check and the send would also do it,
  /// and an operator can lift the cooldown. So the callers cool the payer down for
  /// REVERT_COOLDOWN_SECONDS (an hour) after a revert of a sent transfer whose authorization then
  /// reads unused, or cannot be read. When it reads USED, someone else's transaction may have
  /// executed it first (a mempool copier, on a chain with a public mempool), with the funds arrived:
  /// that payer is only held for UNCONFIRMED_HOLD_SECONDS, as is one whose transfer had not
  /// confirmed within the polls. A payer that cancels after the check is therefore bounded at one
  /// reverting broadcast per 5 minutes.
  /// One reverting broadcast per payer per hour where the polls see it; per 5 minutes where they do
  /// not. A cooldown is never shortened by a later, shorter one. At most `maxCooling` entries (the
  /// sender uses 10_000); when full, expired ones are dropped first, then the one ending soonest.
  /// Transient: an upgrade forgets both maps.
  public class PayerGuard(maxCooling : Nat) {
    let entries = HashMap.HashMap<Text, ()>(16, Text.equal, Text.hash);
    let cooling = HashMap.HashMap<Text, Nat>(16, Text.equal, Text.hash);

    /// The guard key of a payer: (chainId, token, from), on decoded bytes like AuthorizationGuard.
    public func key(chainId : Nat, token : Text, from : [Nat8]) : Text {
      Nat.toText(chainId) # ":" # EvmUtils.bytesToHex(EvmUtils.hexToBytes(token)) # ":" # EvmUtils.bytesToHex(from);
    };

    /// Claim `k`. #busy when that payer already holds it; #coolingDown(until) while it cools down.
    public func claim(k : Text, nowSeconds : Nat) : { #ok; #busy; #coolingDown : Nat } {
      switch (cooling.get(k)) {
        case (?until) { if (nowSeconds < until) { return #coolingDown(until) } else { cooling.delete(k) } };
        case (null) {};
      };
      if (entries.get(k) != null) { return #busy };
      entries.put(k, ());
      #ok;
    };

    /// Free `k` — its call has returned.
    public func release(k : Text) { entries.delete(k) };

    /// Refuse `k` for `seconds` from `nowSeconds` (REVERT_COOLDOWN_SECONDS or
    /// UNCONFIRMED_HOLD_SECONDS); an existing, later end is kept.
    public func coolDown(k : Text, nowSeconds : Nat, seconds : Nat) {
      let until = nowSeconds + seconds;
      switch (cooling.get(k)) {
        case (?existing) { if (existing >= until) { return } };
        case (null) { if (cooling.size() >= maxCooling) { pruneCooling(nowSeconds) } };
      };
      cooling.put(k, until);
    };

    /// Lift `k`'s cooldown (an operator's call). True when it was cooling down.
    public func liftCooldown(k : Text, nowSeconds : Nat) : Bool {
      let was = switch (cooling.get(k)) { case (?until) { nowSeconds < until }; case (null) { false } };
      cooling.delete(k);
      was;
    };

    /// Number of payers with a transfer in flight.
    public func size() : Nat { entries.size() };

    /// Number of payers remembered as cooling down (expired ones included until pruned).
    public func coolingSize() : Nat { cooling.size() };

    /// Lift every cooldown (an operator's call, e.g. for a payer whose transfer reverted by
    /// mistake). Returns how many were remembered.
    public func clearCooldowns() : Nat {
      let n = cooling.size();
      for (k in Iter.toArray(cooling.keys()).values()) { cooling.delete(k) };
      n;
    };

    func pruneCooling(nowSeconds : Nat) {
      for ((k, until) in Iter.toArray(cooling.entries()).values()) {
        if (until <= nowSeconds) { cooling.delete(k) };
      };
      if (cooling.size() >= maxCooling) {
        var soonest : ?(Text, Nat) = null;
        for ((k, until) in cooling.entries()) {
          switch (soonest) {
            case (?(_, at)) { if (until < at) { soonest := ?(k, until) } };
            case (null) { soonest := ?(k, until) };
          };
        };
        switch (soonest) { case (?(k, _)) { cooling.delete(k) }; case (null) {} };
      };
    };
  };

  /// 2.23.1: a token bucket for simulations that do not lead to a send. A simulation is the one
  /// inbound check that costs an outcall (a multi-provider eth_call, ~1.7B cycles on mainnet by one
  /// estimate). Every inbound payment that verifies reaches it, and a wallet that verifies costs
  /// nothing to make, so without a bound below the global facilitator bucket (2 a second) a flood of
  /// unfunded payments spends about as much as the signed broadcasts it replaced. Each simulation
  /// takes a token BEFORE its outcall (so simulations in flight are bounded too); the token is given
  /// back only when the transfer then goes out. A refused simulation, or one that passes but is not
  /// sent (the send lock was taken meanwhile), keeps it. With none left, payments are not checked
  /// until one refills: at most `capacity` at once, and one more every `refillSeconds`, so honest
  /// payments that go out never use it up. Transient, starts full.
  public class SimulationBudget(capacity : Nat, refillSeconds : Nat) {
    var tokens : Nat = capacity;
    var last : Nat = 0;

    func refill(nowSeconds : Nat) {
      if (last == 0) { last := nowSeconds }; // the refill clock starts at the first call
      if (nowSeconds > last) {
        let add = Nat.sub(nowSeconds, last) / refillSeconds;
        if (add > 0) {
          tokens := Nat.min(capacity, tokens + add);
          last += add * refillSeconds;
        };
      };
    };

    /// Take a token at `nowSeconds` for a simulation. False when none is left.
    public func take(nowSeconds : Nat) : Bool {
      refill(nowSeconds);
      if (tokens == 0) { return false };
      tokens := Nat.sub(tokens, 1);
      true;
    };

    /// Give a token back: its transfer was sent.
    public func giveBack() { tokens := Nat.min(capacity, tokens + 1) };
  };

  /// 2.23.1: the gas limit of a transferWithAuthorization broadcast, also the simulation's.
  public let TRANSFER_WITH_AUTHORIZATION_GAS : Nat = 120_000;

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

    /// 2.23.1: the payers with an inbound transfer in flight (see PayerGuard). Gateway.settle and
    /// the session-open deposit claim here; a direct caller of executeTransferWithAuthorization is
    /// not checked (the simulation still runs for it).
    public let inFlightPayers : PayerGuard = PayerGuard(10_000);

    // 2.23.1: at most 10 refused simulations at once, one more every 6 seconds (SimulationBudget).
    let simulationBudget : SimulationBudget = SimulationBudget(10, 6);

    /// 2.23.2: the chains where a broadcast just failed for lack of gas (see GasStops). Set and
    /// checked by sendTransaction; also checked by executeTransferWithAuthorization before the
    /// simulation.
    public let gasStops : GasStops = GasStops(GAS_STOP_SECONDS);

    // Set by stopSends; every send is refused before signing while it is. Transient.
    var sendsStopped : ?Text = null;

    /// Refuse every send from now on, before signing, with SENDS_STOPPED_PREFIX # `reason`.
    /// Gateway calls it when its recipient is not the address this sender signs from. There is no
    /// undo: an upgrade builds a new sender.
    public func stopSends(reason : Text) { sendsStopped := ?(SENDS_STOPPED_PREFIX # reason) };

    // 2.22.0 (F1): the account nonce each tx this sender signed was sent with, by lower-case tx
    // hash, so reconcileTransaction can tell a tx whose nonce another tx took from one still pending.
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
    // mint a paid receipt / credit an escrow. `min = 2` requires at least two to agree (vs. the
    // prior `null` config, which could act on a single provider's answer for the 2-provider custom
    // chains). 2.23.1: the config depends on the services — see EvmRpc.consensusConfig.
    func rpcConfig(services : EvmRpc.RpcServices) : ?EvmRpc.RpcConfig { EvmRpc.consensusConfig(services) };

    // Ops cycle floor: refuse to BROADCAST a tx the canister can't afford to also CONFIRM.
    // A full settle is ~7 EVM-RPC outcalls (fee + nonce + send + up to 4 receipt polls) plus a
    // tECDSA sign — on the order of 100B cycles. Below this floor sendTransaction returns a
    // PRE-broadcast #err (no funds move; every caller rolls back safely) instead of broadcasting
    // and then freezing mid-confirm — which is exactly what leaves a transfer parked. Top up the
    // canister to clear it. (Surfaced via the example's `health` query cycle balance.)
    let MIN_BROADCAST_CYCLES : Nat = 120_000_000_000;
    let LOW_CYCLES_TEXT : Text = "Insufficient cycles to safely broadcast and confirm; top up the canister";
    // 2.23.1: new inbound transfers (and their simulation, an outcall anyone can trigger) stop here,
    // above MIN_BROADCAST_CYCLES, so a flood of them cannot spend the reserve closes and refunds need.
    let MIN_INBOUND_CYCLES : Nat = 500_000_000_000;
    // A receipt poll attaches RPC_CYCLES to its outcall, and attaching more than the canister can
    // spare traps (no catch runs, and the caller gets a reject). Below this floor confirmTransaction
    // answers #err before the outcall instead: "status unknown", which no caller reads as not sent.
    // Well under MIN_BROADCAST_CYCLES, so a send that passed its floor can still confirm.
    let MIN_CONFIRM_CYCLES : Nat = 20_000_000_000;

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
      switch (sendsStopped) { case (?e) { return #err(e) }; case (null) {} }; // stopSends
      // 2.23.2: a chain the canister just could not pay gas on (GasStops): refused before signing,
      // for every send. Pre-broadcast #err: nothing moves, callers roll back as for any other.
      switch (gasStops.stoppedUntil(chainId, Int.abs(Time.now() / 1_000_000_000))) {
        case (?until) { return #err(gasStopText(chainId, until)) };
        case (null) {};
      };
      // Cycle floor (see MIN_BROADCAST_CYCLES): never broadcast a tx we can't afford to confirm.
      // Pre-broadcast #err => no funds move and callers roll back safely.
      if (Cycles.balance() < MIN_BROADCAST_CYCLES) {
        return #err(LOW_CYCLES_TEXT);
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
            services, rpcConfig(services), { address = senderAddr; block = #Pending },
          )
        ) {
          case (#Consistent(#Ok(n))) { n };
          case (_) {
            txInProgress := false;
            return #err(NONCE_READ_FAILED # ": eth_getTransactionCount did not reach multi-provider consensus. Nothing was broadcast — safe to retry. If it persists, check the EVM-RPC canister's providers/cycles for this chain.");
          };
        };

        // H-3: Get fee data; if unavailable, do NOT broadcast a low-fee tx.
        let (maxFee, priorityFee) = switch (await getFeeData(evmRpc, services)) {
          case (?fd) { fd };
          case (null) {
            txInProgress := false;
            return #err(FEE_DATA_UNAVAILABLE # " — not broadcasting (retry later)");
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
          await (with cycles = EvmRpc.RPC_CYCLES) evmRpc.eth_sendRawTransaction(services, rpcConfig(services), rawTxHex);
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
                  services, rpcConfig(services), { address = senderAddr; block = #Pending },
                )
              ) {
                case (#Consistent(#Ok(p))) { p > nonce };
                case (_) { false };
              };
            } catch (_) { false };
            if (moved) {
              #maybeSent({ txHash = broadcastTxHash; reason = GAS_REFUSAL_NONCE_MOVED });
            } else {
              gasStops.stop(chainId, Int.abs(Time.now() / 1_000_000_000)); // 2.23.2 (GasStops)
              outcome;
            };
          };
          case (_) {
            // 2.23.2: weaker evidence of a gas shortage (a provider error, or a disagreement where
            // none accepted) stops the chain too; the outcome (maybe sent) is unchanged.
            if (gasShortageReported(sendResult)) { gasStops.stop(chainId, Int.abs(Time.now() / 1_000_000_000)) };
            outcome;
          };
        };
      } catch (e) {
        // Exception BEFORE the broadcast (pubkey / nonce / fee / signing) — no tx sent.
        #err(FAILED_BEFORE_BROADCAST # ": " # Error.message(e));
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
    ///                      unavailable, or a confirm call that was rejected): it MAY
    ///                      have landed, so callers MUST NOT
    ///                      finalize AND MUST NOT auto-retry by re-calling this (a
    ///                      re-broadcast signs a fresh nonce and double-pays) — re-poll
    ///                      confirmTransaction on the hash, or recover manually.
    ///   #err(msg)        — failed BEFORE broadcast (no tx sent): safe to roll back.
    /// A reject of the send itself (a reply it cannot decode, say) still propagates, with no hash:
    /// the tx may have gone out, so a caller treats it as maybe sent, never as #err.
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
          // A confirm call that is rejected (a reply it cannot decode traps it) decides nothing:
          // the tx is out, so it is pending, never a throw that loses its hash.
          let c : { #confirmed; #reverted; #pending; #err : Text } = try { await confirmTransaction(chainId, m.txHash, maxPolls) } catch (_) { #pending };
          switch (c) {
            case (#confirmed) { #confirmed(m.txHash) };
            case (#reverted) { #reverted(m.txHash) };
            case (_) { #pending(m.txHash) };
          };
        };
        case (#ok(txHash)) {
          let c : { #confirmed; #reverted; #pending; #err : Text } = try { await confirmTransaction(chainId, txHash, maxPolls) } catch (_) { #pending };
          switch (c) {
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
      // 2.23.1: sign only what the chain says will succeed (see "Simulate before signing"). The
      // cheap refusals come first, so they cost no outcall: an authorization that expires too soon,
      // a chain the canister just could not pay gas on (2.23.2, GasStops; final, so before the
      // busy lock's "retry"), a busy send lock (sendTransaction checks both again), cycles below
      // the inbound reserve, and an exhausted simulation budget. Every refusal here is #err:
      // nothing was signed or broadcast.
      let nowSeconds = Int.abs(Time.now() / 1_000_000_000);
      if (EvmUtils.hexToBytes(tokenAddress).size() != 20) {
        return #err("Invalid token address (expected 20 bytes): " # tokenAddress # "; nothing was signed or sent");
      };
      if (expiresTooSoon(validBefore, nowSeconds)) { return #err(EXPIRES_TOO_SOON) };
      switch (sendsStopped) { case (?e) { return #err(e) }; case (null) {} }; // stopSends
      switch (gasStops.stoppedUntil(chainId, nowSeconds)) {
        case (?until) { return #err(gasStopText(chainId, until)) };
        case (null) {};
      };
      if (txInProgress) { return #err(INBOUND_SEND_BUSY) };
      if (Cycles.balance() < MIN_INBOUND_CYCLES) { return #err(LOW_INBOUND_CYCLES) };
      if (not simulationBudget.take(nowSeconds)) { return #err(SIMULATION_BUSY) };
      switch (simulationRefusal(await* simulate(chainId, tokenAddress, calldata), validAfter, nowSeconds)) {
        case (null) {};
        case (?refusal) { return #err(refusal) }; // the budget token stays spent
      };
      // transferWithAuthorization uses more gas than a simple transfer (~80k).
      // B2 (G5/G6): SURFACE #maybeSent (with its tx hash), do not collapse it to #err. The inbound
      // EIP-3009 path is replay-protected on-chain (the authorization's token nonce is single-use),
      // so an ambiguous broadcast cannot double-pay — but it MAY still mine, so the caller must keep
      // the tx hash to poll/reconcile it rather than stranding a hash-less #settlementFailed. Callers
      // (Gateway.settle, Sessions.openEvmSession) route the hash into confirmTransaction.
      switch (await sendTransaction(chainId, tokenAddress, calldata, TRANSFER_WITH_AUTHORIZATION_GAS)) {
        case (#ok(h)) { simulationBudget.giveBack(); #ok(h) };
        // Not sent: the budget token stays spent. A failure that clears by itself asks the payer
        // to retry the same payment (2.23.1).
        case (#err(e)) {
          if (isSendBusy(e)) { #err(INBOUND_SEND_BUSY) } else if (transientSendError(e)) {
            #err(e # " Nothing of this payment was sent — retry this same payment shortly.");
          } else if (isInsufficientGas(e)) {
            // 2.23.2: sendTransaction has stopped sends on this chain (GasStops).
            #err(e # " Payments and sends on chain " # Nat.toText(chainId) # " are refused for the next " # Nat.toText(GAS_STOP_SECONDS / 60) # " minutes, or until the operator lifts the stop.");
          } else { #err(e) };
        };
        case (#maybeSent(m)) { simulationBudget.giveBack(); #maybeSent(m) };
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
          services, rpcConfig(services),
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
        if (Cycles.balance() < MIN_CONFIRM_CYCLES) {
          return #err("Insufficient cycles to poll the receipt — transaction status unknown (it may still mine). Top up the canister, then re-poll with the same tx hash; never re-broadcast on this outcome.");
        };
        let result = try {
          await (with cycles = EvmRpc.RPC_CYCLES) evmRpc.eth_getTransactionReceipt(services, rpcConfig(services), txHash);
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
    /// the nonce the tx was signed with — another transaction took that nonce, so this one
    /// appears not to have landed. Checked in that order and the receipt read once more after the
    /// count, so a tx mined in between is not reported dropped; that last read must be an explicit,
    /// agreed "no receipt" (finalReceiptVerdict) — no answer stays #pending. A lagging provider
    /// pair can still agree on "no receipt" for a mined tx, so callers REPORT #dropped and leave
    /// the decision to an operator, who verifies on chain first. Without a remembered nonce (another instance's tx, or after an upgrade) the
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
                services, rpcConfig(services), { address = await getEvmAddress(); block = #Latest },
              )
            ) {
              case (#Consistent(#Ok(c))) { c };
              case (_) { return #pending };
            };
          } catch (_) { return #pending };
          if (not txNonceConsumed(n, latest)) { return #pending };
          // Round 2: one explicit read, not confirmTransaction — that folds "no answer" (providers
          // disagreeing, an RPC error, a status-less receipt) into #pending, which was then
          // reported as dropped.
          let last = try {
            await (with cycles = EvmRpc.RPC_CYCLES) evmRpc.eth_getTransactionReceipt(services, rpcConfig(services), txHash);
          } catch (_) { return #pending };
          switch (finalReceiptVerdict(last)) {
            case (#confirmed) { #confirmed };
            case (#reverted) { #reverted };
            case (#pending) { #pending };
            case (#dropped) {
              #dropped("no receipt for this tx, and the account has mined " # Nat.toText(latest) # " transactions — nonce " # Nat.toText(n) # " was used by another transaction");
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
          // 2.23.1: the canonical 0x form — the EVM-RPC canister refuses a `to` without the prefix,
          // and a payer chooses the asset's spelling.
          type_ = null; nonce = null; to = ?EvmUtils.bytesToHex(EvmUtils.hexToBytes(tokenAddress)); from = null; gas = null; value = null;
          input = ?EvmUtils.bytesToHex(buildAuthorizationStateCalldata(authorizer, authNonce));
          gasPrice = null; maxPriorityFeePerGas = null; maxFeePerGas = null; maxFeePerBlobGas = null;
          accessList = null; blobVersionedHashes = null; blobs = null; chainId = null;
        };
        block = ?#Latest;
      };
      try {
        classifyAuthorizationState(await (with cycles = EvmRpc.RPC_CYCLES) evmRpc.eth_call(services, rpcConfig(services), call));
      } catch (e) { #unknown("authorizationState call failed: " # Error.message(e)) };
    };

    /// 2.23.1: simulate `calldata` against `tokenAddress` as an eth_call at the latest block,
    /// through the EVM-RPC canister (the same 2-of-N agreement as every other read), exactly as the
    /// broadcast will run it: from this sender's own address (the transaction's origin) and with its
    /// gas limit. A payer with code (USDC asks it to check the signature, e.g. an EIP-7702 delegate)
    /// can still tell the two apart by block, time or gas price; PayerGuard's cooldown bounds that.
    /// The token is sent in canonical 0x form. Never signs or broadcasts. A rejected call is #unknown.
    func simulate(chainId : Nat, tokenAddress : Text, calldata : [Nat8]) : async* SimulationVerdict {
      let (evmRpc, services) = switch (EvmRpc.resolveRpc(evmRpcCanister, chainId)) {
        case (?r) { r };
        case (null) { return #unknown("Unsupported chain ID: " # Nat.toText(chainId)) };
      };
      try {
        let self = switch (cachedEvmAddr) { case (?a) { a }; case (null) { await getEvmAddress() } };
        if (self == "") { return #unknown("this canister's EVM address could not be derived") };
        let call : EvmRpc.CallArgs = {
          transaction = {
            type_ = null; nonce = null; to = ?EvmUtils.bytesToHex(EvmUtils.hexToBytes(tokenAddress)); from = ?self;
            gas = ?TRANSFER_WITH_AUTHORIZATION_GAS; value = null;
            input = ?EvmUtils.bytesToHex(calldata);
            gasPrice = null; maxPriorityFeePerGas = null; maxFeePerGas = null; maxFeePerBlobGas = null;
            accessList = null; blobVersionedHashes = null; blobs = null; chainId = null;
          };
          block = ?#Latest;
        };
        classifySimulation(await (with cycles = EvmRpc.RPC_CYCLES) evmRpc.eth_call(services, rpcConfig(services), call));
      } catch (e) { #unknown("simulation call failed: " # Error.message(e)) };
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
