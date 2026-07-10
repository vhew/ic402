/// Candid-mirror probe for the EVM-RPC canister surface — NOT a mops test
/// (deliberately no `.test.mo` suffix so `mops test` skips it).
///
/// A minimal actor whose public methods are EXACTLY EvmRpc.EvmRpcCanister's four
/// methods (the only EVM-RPC methods ic402's Motoko ever calls, all via
/// EvmSender/EvmVerify: eth_getTransactionReceipt, eth_getTransactionCount,
/// eth_sendRawTransaction, eth_feeHistory), typed with the repo's mirror types.
/// Compiling this file with `moc --idl` emits the mirror's .did, which
/// scripts/check-candid-mirrors.sh compares against the vendored official
/// evm_rpc.did @ v2.8.0 (test/fixtures/official/) via a pinned `didc check`.
///
/// The `_self` witness makes the probe's surface provably a subtype of
/// EvmRpc.EvmRpcCanister at compile time: if EvmRpcCanister gains a method or a
/// signature changes and this probe is not updated to match, the probe stops
/// compiling and the gate fails loudly instead of silently shrinking coverage.
import EvmRpc "../../src/ic402/EvmRpc";

persistent actor EvmRpcProbe {
  transient let _self : EvmRpc.EvmRpcCanister = EvmRpcProbe;

  public shared func eth_getTransactionReceipt(_s : EvmRpc.RpcServices, _c : ?EvmRpc.RpcConfig, _txHash : Text) : async EvmRpc.MultiGetTransactionReceiptResult {
    #Consistent(#Err(#ProviderError(#NoPermission)));
  };
  public shared func eth_getTransactionCount(_s : EvmRpc.RpcServices, _c : ?EvmRpc.RpcConfig, _args : EvmRpc.GetTransactionCountArgs) : async EvmRpc.MultiGetTransactionCountResult {
    #Consistent(#Ok(0));
  };
  public shared func eth_sendRawTransaction(_s : EvmRpc.RpcServices, _c : ?EvmRpc.RpcConfig, _rawTx : Text) : async EvmRpc.MultiSendRawTransactionResult {
    #Consistent(#Ok(#NonceTooLow));
  };
  public shared func eth_feeHistory(_s : EvmRpc.RpcServices, _c : ?EvmRpc.RpcConfig, _args : EvmRpc.FeeHistoryArgs) : async EvmRpc.MultiFeeHistoryResult {
    #Consistent(#Err(#ProviderError(#NoPermission)));
  };
};
