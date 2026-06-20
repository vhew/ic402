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
///   setFeeMode(#consistent)                  one agreed base fee
///   setFeeMode(#inconsistentOutlier)         two providers disagree, one a wild outlier,
///                                            so the caller's robust-median fee logic runs
/// ============================================================================

import EvmRpc "../../src/ic402/EvmRpc";
import Nat "mo:base/Nat";
import Array "mo:base/Array";

persistent actor EvmRpcMock {

  public type ReceiptMode = {
    #confirmed;
    #reverted;
    #pendingThenConfirmed : Nat;
  };

  public type FeeMode = {
    #consistent;
    #inconsistentOutlier;
  };

  // ── scriptable state ──
  var receiptMode : ReceiptMode = #confirmed;
  var feeMode : FeeMode = #consistent;
  var receiptPolls : Nat = 0; // receipt polls since the last setReceiptMode/reset
  var nonce : Nat = 0; // monotonic, advances once per eth_getTransactionCount
  var sentTxs : [Text] = []; // every raw tx we were asked to broadcast, in order

  // ── test hooks (open by design — see header warning) ──

  public func setReceiptMode(m : ReceiptMode) : async () {
    receiptMode := m;
    receiptPolls := 0;
  };

  public func setFeeMode(m : FeeMode) : async () { feeMode := m };

  /// Reset to a pristine confirmed/consistent fixture and forget sent txs.
  public func reset() : async () {
    receiptMode := #confirmed;
    feeMode := #consistent;
    receiptPolls := 0;
    nonce := 0;
    sentTxs := [];
  };

  public query func getSentTxs() : async [Text] { sentTxs };
  public query func sentTxCount() : async Nat { sentTxs.size() };
  public query func getReceiptPolls() : async Nat { receiptPolls };

  // ── EvmRpc.EvmRpcCanister interface (the 4 methods the library calls) ──

  public func eth_sendRawTransaction(
    _services : EvmRpc.RpcServices,
    _config : ?EvmRpc.RpcConfig,
    rawTx : Text,
  ) : async EvmRpc.MultiSendRawTransactionResult {
    sentTxs := Array.append(sentTxs, [rawTx]);
    #Consistent(#Ok(#Ok(?mockTxHash(sentTxs.size()))));
  };

  public func eth_getTransactionCount(
    _services : EvmRpc.RpcServices,
    _config : ?EvmRpc.RpcConfig,
    _args : EvmRpc.GetTransactionCountArgs,
  ) : async EvmRpc.MultiGetTransactionCountResult {
    let n = nonce;
    nonce += 1;
    #Consistent(#Ok(n));
  };

  public func eth_getTransactionReceipt(
    _services : EvmRpc.RpcServices,
    _config : ?EvmRpc.RpcConfig,
    txHash : Text,
  ) : async EvmRpc.MultiGetTransactionReceiptResult {
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
    };
  };

  public func eth_feeHistory(
    _services : EvmRpc.RpcServices,
    _config : ?EvmRpc.RpcConfig,
    _args : EvmRpc.FeeHistoryArgs,
  ) : async EvmRpc.MultiFeeHistoryResult {
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
