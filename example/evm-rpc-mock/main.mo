/// ============================================================================
/// evm-rpc-mock — a hermetic TEST DOUBLE for the DFINITY EVM RPC canister.
///
/// ⚠️  TEST FIXTURE ONLY. Never deploy this to mainnet. The scriptable hooks are
///     intentionally unauthenticated so CI can drive them without controller
///     juggling; on a real network that would let anyone forge receipts.
///
/// WHY IT EXISTS (production-readiness item B3):
///   The EVM-outbound path — sign (tECDSA) → RLP → eth_sendRawTransaction →
///   poll eth_getTransactionReceipt → confirm / park / reconcile — could only be
///   exercised against a funded public testnet, so CI never gated it. This canister
///   implements the exact `EvmRpc.EvmRpcCanister` interface the library calls, with
///   canned, *scriptable* responses, so the whole state machine runs on a local
///   replica with NO funded account and NO HTTPS outcalls.
///
///   What stays REAL in the test: the canister-under-test still does genuine tECDSA
///   signing + RLP encoding; only the broadcast/confirm round-trip hits this mock.
///   We record every raw tx we were asked to broadcast so a test can assert the
///   bytes actually went out (and that we did not double-broadcast).
///
/// SCRIPTING (call before driving the canister-under-test):
///   setReceiptMode(#confirmed)               receipts report status=1 (mined OK)
///   setReceiptMode(#reverted)                receipts report status=0 (mined, reverted)
///   setReceiptMode(#pendingThenConfirmed n)  first n receipt polls => null (not yet
///                                            mined → caller parks); poll n+1 => status=1
///   setReceiptMode(#inconsistent)            providers disagree (one null, one mined) — no
///                                            answer (2.22.0 round 2)
///   setReceiptMode(#error)                   every provider errors — no answer
///   setFeeMode(#consistent)                  one agreed base fee
///   setFeeMode(#inconsistentOutlier)         two providers disagree, one a wild outlier,
///                                            so the caller's robust-median fee logic runs
///   setFeeMode(#unavailable)                 every provider errors → the send refuses
///                                            BEFORE broadcasting (2.22.0)
///   setSendMode(#ok | #nonceTooHigh | #nonceTooLow | #insufficientFunds
///               | #insufficientFundsInconsistent)
///                                            how eth_sendRawTransaction answers
///   setPendingNonce(?n)                      pin eth_getTransactionCount(#Pending) at n;
///                                            null (default) = advance by one per call
///   setLatestNonce(n)                        eth_getTransactionCount(#Latest) — the mined
///                                            count (default 0: nothing ever mined)
///   setAuthStateMode(#unused | #used | #error)
///                                            the authorizationState eth_call's answer
///   setSimulationMode(#ok | #reverted | #revertedInconsistent | #inconsistent | #error)
///                                            2.23.1: the answer to the eth_call that simulates
///                                            a transferWithAuthorization before signing
///                                            (told apart by its selector, 0xe3ee160e)
///   setHoldSimulations(true | false)         2.23.1: while true, a simulation is counted but
///                                            does not answer, so its caller stays in flight
///                                            (holding its payer slot) until set false (or
///                                            a minute passes)
///
/// 2.23.1: eth_call rejects a `to` or `from` without the 0x prefix, as the real canister's Hex20
/// decoding does.
/// 2.23.1: like the real EVM-RPC canister, every method refuses a Threshold consensus without
/// `total` for default-provider services (#EthMainnet(null), #BaseMainnet(null), …) with
/// InvalidRpcConfig. ic402 sent exactly that from 2.1.0 to 2.23.0; this mock ignored the config,
/// so the hermetic suite never saw every call on those chains fail.
/// ============================================================================

import EvmRpc "../../src/ic402/EvmRpc";
import Nat "mo:base/Nat";
import Array "mo:base/Array";
import Text "mo:base/Text";
import Time "mo:base/Time";
import Debug "mo:base/Debug";

persistent actor EvmRpcMock {

  public type ReceiptMode = {
    #confirmed;
    #reverted;
    #pendingThenConfirmed : Nat;
    // 2.22.0 round 2: receipt reads that give NO answer — a mined tx read during provider lag or
    // an outage looks like this, and must never be reported as "not landed".
    #inconsistent;
    #error;
  };

  public type FeeMode = {
    #consistent;
    #inconsistentOutlier;
    // 2.22.0: no provider has fee data — the library refuses to broadcast (a pre-broadcast #err).
    #unavailable;
  };

  // 2.22.0: what eth_call (authorizationState) answers.
  public type AuthStateMode = {
    #unused;
    #used;
    #error;
  };

  // 2.23.1: what the simulation (eth_call of transferWithAuthorization) answers. #reverted: every
  // provider reports the same revert. #revertedInconsistent: every provider reverts, in different
  // words. #inconsistent: one says it succeeds, one that it reverts. #error: no provider answers.
  public type SimulationMode = {
    #ok;
    #reverted;
    #revertedInconsistent;
    #inconsistent;
    #error;
  };

  // G5/G6: how eth_sendRawTransaction resolves. #ok = clean broadcast; #nonceTooHigh makes the
  // send AMBIGUOUS (#Consistent(#Ok(#NonceTooHigh))), which the library maps to #maybeSent — the
  // tx may have reached a mempool, so its hash must be preserved/tracked, not discarded as #err.
  public type SendMode = {
    #ok;
    #nonceTooHigh;
    // 2.21.1: NonceTooLow can follow the inclusion of this very tx (a send is not idempotent),
    // so the library maps it to #maybeSent too, never to a safe-to-retry failure.
    #nonceTooLow;
    // 2.22.0: the agreeing providers say the gas account is unfunded. The library re-reads the
    // pending nonce: moved past the tx → #maybeSent; not moved → #err (nothing broadcast).
    #insufficientFunds;
    // 2.23.2: the providers disagree — one says the gas account is unfunded, one fails — and none
    // accepted. The library reports #maybeSent, and stops the chain (gasShortageReported).
    #insufficientFundsInconsistent;
  };

  // ── scriptable state ──
  var receiptMode : ReceiptMode = #confirmed;
  var feeMode : FeeMode = #consistent;
  var sendMode : SendMode = #ok;
  var receiptPolls : Nat = 0; // receipt polls since the last setReceiptMode/reset
  var nonce : Nat = 0; // monotonic, advances once per eth_getTransactionCount(#Pending) unless pinned
  var pendingNoncePin : ?Nat = null; // 2.22.0: pinned #Pending answer
  var latestNonce : Nat = 0; // 2.22.0: the #Latest (mined) count
  var authStateMode : AuthStateMode = #unused; // 2.22.0
  var ethCalls : Nat = 0; // 2.22.0: authorizationState eth_call count since reset
  var simulationMode : SimulationMode = #ok; // 2.23.1
  var simulations : Nat = 0; // 2.23.1: simulation eth_calls since reset
  var lastSimulation : ?{ to : ?Text; from : ?Text; gas : ?Nat; input : Text } = null; // 2.23.1
  var holdSimulations : Bool = false; // 2.23.1
  var sentTxs : [Text] = []; // every raw tx we were asked to broadcast, in order

  // ── test hooks (open by design — see header warning) ──

  public func setReceiptMode(m : ReceiptMode) : async () {
    receiptMode := m;
    receiptPolls := 0;
  };

  public func setFeeMode(m : FeeMode) : async () { feeMode := m };

  public func setSendMode(m : SendMode) : async () { sendMode := m };

  public func setPendingNonce(n : ?Nat) : async () { pendingNoncePin := n };

  public func setLatestNonce(n : Nat) : async () { latestNonce := n };

  public func setAuthStateMode(m : AuthStateMode) : async () { authStateMode := m };

  public func setSimulationMode(m : SimulationMode) : async () { simulationMode := m };

  public func setHoldSimulations(b : Bool) : async () { holdSimulations := b };

  // A held simulation waits one consensus round per check (raw_rand answers in the next round). A
  // self-call loop would also wait, but a replica can run many self-calls in one round, starving
  // the other canisters of execution.
  transient let management : actor { raw_rand : () -> async Blob } = actor "aaaaa-aa";

  /// Reset to a pristine confirmed/consistent fixture and forget sent txs.
  public func reset() : async () {
    receiptMode := #confirmed;
    feeMode := #consistent;
    sendMode := #ok;
    receiptPolls := 0;
    nonce := 0;
    pendingNoncePin := null;
    latestNonce := 0;
    authStateMode := #unused;
    ethCalls := 0;
    simulationMode := #ok;
    simulations := 0;
    lastSimulation := null;
    holdSimulations := false;
    sentTxs := [];
  };

  public query func getSentTxs() : async [Text] { sentTxs };
  public query func sentTxCount() : async Nat { sentTxs.size() };
  public query func getReceiptPolls() : async Nat { receiptPolls };
  public query func getEthCalls() : async Nat { ethCalls };
  public query func getSimulations() : async Nat { simulations };
  public query func getLastSimulation() : async ?{ to : ?Text; from : ?Text; gas : ?Nat; input : Text } { lastSimulation };

  // 2.23.1: what the real EVM-RPC canister answers to a Threshold without `total` on its default
  // providers (it needs to know how many to query).
  func configError(services : EvmRpc.RpcServices, config : ?EvmRpc.RpcConfig) : ?EvmRpc.RpcError {
    let defaults = switch (services) {
      case (#EthMainnet(null)) { true };
      case (#EthSepolia(null)) { true };
      case (#ArbitrumOne(null)) { true };
      case (#BaseMainnet(null)) { true };
      case (#OptimismMainnet(null)) { true };
      case (_) { false };
    };
    switch (config) {
      case (?{ responseConsensus = ?#Threshold({ total = null }) }) {
        if (defaults) { ?#ProviderError(#InvalidRpcConfig("total must be specified when using default providers")) } else { null };
      };
      case (_) { null };
    };
  };

  // ── EvmRpc.EvmRpcCanister interface (the 5 methods the library calls) ──

  public func eth_sendRawTransaction(
    services : EvmRpc.RpcServices,
    config : ?EvmRpc.RpcConfig,
    rawTx : Text,
  ) : async EvmRpc.MultiSendRawTransactionResult {
    switch (configError(services, config)) { case (?e) { return #Consistent(#Err(e)) }; case (null) {} };
    sentTxs := Array.append(sentTxs, [rawTx]);
    switch (sendMode) {
      // G5/G6: ambiguous broadcast — the raw tx was recorded (it may have reached a mempool), but
      // the RPC reports NonceTooHigh, which the library maps to #maybeSent(txHash). The caller must
      // preserve the hash (poll/track) rather than treat it as a clean, safe-to-retry failure.
      case (#nonceTooHigh) { #Consistent(#Ok(#NonceTooHigh)) };
      case (#nonceTooLow) { #Consistent(#Ok(#NonceTooLow)) };
      case (#insufficientFunds) { #Consistent(#Ok(#InsufficientFunds)) };
      case (#insufficientFundsInconsistent) {
        #Inconsistent([(#Provider(1 : Nat64), #Ok(#InsufficientFunds)), (#Provider(2 : Nat64), #Err(#JsonRpcError({ code = -32000; message = "upstream request timed out" })))]);
      };
      case (#ok) { #Consistent(#Ok(#Ok(?mockTxHash(sentTxs.size())))) };
    };
  };

  public func eth_getTransactionCount(
    services : EvmRpc.RpcServices,
    config : ?EvmRpc.RpcConfig,
    args : EvmRpc.GetTransactionCountArgs,
  ) : async EvmRpc.MultiGetTransactionCountResult {
    switch (configError(services, config)) { case (?e) { return #Consistent(#Err(e)) }; case (null) {} };
    switch (args.block, pendingNoncePin) {
      case (#Latest, _) { #Consistent(#Ok(latestNonce)) };
      case (_, ?p) { #Consistent(#Ok(p)) };
      case (_, null) {
        let n = nonce;
        nonce += 1;
        #Consistent(#Ok(n));
      };
    };
  };

  public func eth_getTransactionReceipt(
    services : EvmRpc.RpcServices,
    config : ?EvmRpc.RpcConfig,
    txHash : Text,
  ) : async EvmRpc.MultiGetTransactionReceiptResult {
    switch (configError(services, config)) { case (?e) { return #Consistent(#Err(e)) }; case (null) {} };
    receiptPolls += 1;
    switch (receiptMode) {
      case (#confirmed) { #Consistent(#Ok(?receipt(txHash, 1))) };
      case (#reverted) { #Consistent(#Ok(?receipt(txHash, 0))) };
      case (#pendingThenConfirmed(n)) {
        // First n polls: not yet mined (null) → caller should park. Then: mined OK.
        if (receiptPolls > n) { #Consistent(#Ok(?receipt(txHash, 1))) } else {
          #Consistent(#Ok(null));
        };
      };
      case (#inconsistent) {
        #Inconsistent([
          (#EthSepolia(#Sepolia), #Ok(null)),
          (#EthSepolia(#Ankr), #Ok(?receipt(txHash, 1))),
        ]);
      };
      case (#error) { #Consistent(#Err(#ProviderError(#NoPermission))) };
    };
  };

  public func eth_feeHistory(
    services : EvmRpc.RpcServices,
    config : ?EvmRpc.RpcConfig,
    _args : EvmRpc.FeeHistoryArgs,
  ) : async EvmRpc.MultiFeeHistoryResult {
    switch (configError(services, config)) { case (?e) { return #Consistent(#Err(e)) }; case (null) {} };
    let normal : EvmRpc.FeeHistory = feeHistory(1_000_000_000); // 1 gwei
    switch (feeMode) {
      case (#consistent) { #Consistent(#Ok(normal)) };
      case (#inconsistentOutlier) {
        // Two providers disagree; one returns a 9000-gwei outlier. The caller's
        // robust-median logic must NOT pick the outlier as the base fee.
        let outlier : EvmRpc.FeeHistory = feeHistory(9_000_000_000_000);
        #Inconsistent([
          (#EthSepolia(#Sepolia), #Ok(normal)),
          (#EthSepolia(#Ankr), #Ok(outlier)),
        ]);
      };
      case (#unavailable) { #Consistent(#Err(#ProviderError(#NoPermission))) };
    };
  };

  // The library makes two eth_calls. 2.23.1: a simulation of transferWithAuthorization (selector
  // 0xe3ee160e) before signing an inbound transfer — answered per simulationMode. 2.22.0: the
  // EIP-3009 view authorizationState(authorizer, nonce), read after an inbound transfer reverted —
  // one ABI bool word (or an error) per authStateMode.
  public func eth_call(
    services : EvmRpc.RpcServices,
    config : ?EvmRpc.RpcConfig,
    args : EvmRpc.CallArgs,
  ) : async EvmRpc.MultiCallResult {
    switch (configError(services, config)) { case (?e) { return #Consistent(#Err(e)) }; case (null) {} };
    // 2.23.1: the real canister decodes `to` and `from` as Hex20, which needs the 0x prefix; a
    // value without it fails the call itself (a reject here, as there).
    for (a in [args.transaction.to, args.transaction.from].values()) {
      switch (a) { case (?t) { if (not Text.startsWith(t, #text "0x")) { Debug.trap("Hex20: a 0x prefix is required") } }; case (null) {} };
    };
    let input = switch (args.transaction.input) { case (?i) { i }; case (null) { "" } };
    if (Text.startsWith(Text.toLowercase(input), #text "0xe3ee160e")) {
      simulations += 1;
      lastSimulation := ?{ to = args.transaction.to; from = args.transaction.from; gas = args.transaction.gas; input };
      let deadline = Time.now() + 60_000_000_000; // never hold past a minute (a test that died mid-hold)
      while (holdSimulations and Time.now() < deadline) { ignore await management.raw_rand() };
      let revert = #JsonRpcError({ code = 3 : Int64; message = "execution reverted: FiatTokenV2: transfer amount exceeds balance" });
      return switch (simulationMode) {
        case (#ok) { #Consistent(#Ok("0x")) };
        case (#reverted) { #Consistent(#Err(revert)) };
        case (#revertedInconsistent) {
          #Inconsistent([
            (#EthSepolia(#Sepolia), #Err(revert)),
            (#EthSepolia(#Ankr), #Err(#JsonRpcError({ code = -32000 : Int64; message = "execution reverted" }))),
          ]);
        };
        case (#inconsistent) {
          #Inconsistent([
            (#EthSepolia(#Sepolia), #Ok("0x")),
            (#EthSepolia(#Ankr), #Err(revert)),
          ]);
        };
        case (#error) { #Consistent(#Err(#ProviderError(#NoPermission))) };
      };
    };
    ethCalls += 1;
    switch (authStateMode) {
      case (#unused) { #Consistent(#Ok("0x0000000000000000000000000000000000000000000000000000000000000000")) };
      case (#used) { #Consistent(#Ok("0x0000000000000000000000000000000000000000000000000000000000000001")) };
      case (#error) { #Consistent(#Err(#ProviderError(#NoPermission))) };
    };
  };

  // ── helpers ──

  func feeHistory(baseFee : Nat) : EvmRpc.FeeHistory {
    {
      reward = [];
      gasUsedRatio = [0.5];
      oldestBlock = 100;
      baseFeePerGas = [baseFee, baseFee]; // [current, next-block forecast]
    };
  };

  func receipt(txHash : Text, status : Nat) : EvmRpc.TransactionReceipt {
    {
      to = ?"0x0000000000000000000000000000000000000001";
      status = ?status;
      root = null;
      transactionHash = txHash;
      blockNumber = 100;
      from = "0x0000000000000000000000000000000000000002";
      logs = [];
      blockHash = "0x0000000000000000000000000000000000000000000000000000000000000abc";
      transactionIndex = 0;
      effectiveGasPrice = 1_000_000_000;
      logsBloom = "0x00";
      contractAddress = null;
      gasUsed = 80_000;
      cumulativeGasUsed = 80_000;
    };
  };

  /// Deterministic 32-byte (64-hex) placeholder hash. The caller only uses this as
  /// an opaque handle to poll the receipt for; the mock answers any hash, so the
  /// exact value is irrelevant — only its stability per send matters.
  func mockTxHash(n : Nat) : Text {
    var s = Nat.toText(n);
    while (s.size() < 64) { s := "0" # s };
    "0x" # s;
  };
};
