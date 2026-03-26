/// ic402 — Shared EVM RPC canister types and chain configuration.
///
/// Provides the Candid-compatible types for the DFINITY EVM RPC Canister
/// (7hfb6-caaaa-aaaar-qadga-cai) and chain-to-RPC-service mappings.
/// Used by both EvmVerify (payment verification) and Identity (tx signing).

import Nat "mo:base/Nat";

module {

  // ═══════════════════════════════════════════════════════════════════════
  // Core types (from evm_rpc.did)
  // ═══════════════════════════════════════════════════════════════════════

  public type LogEntry = {
    transactionHash : ?Text;
    blockNumber : ?Nat;
    data : Text;
    blockHash : ?Text;
    transactionIndex : ?Nat;
    topics : [Text];
    address : Text;
    logIndex : ?Nat;
    removed : Bool;
  };

  public type TransactionReceipt = {
    to : ?Text;
    status : ?Nat;
    root : ?Text;
    transactionHash : Text;
    blockNumber : Nat;
    from : Text;
    logs : [LogEntry];
    blockHash : Text;
    transactionIndex : Nat;
    effectiveGasPrice : Nat;
    logsBloom : Text;
    contractAddress : ?Text;
    gasUsed : Nat;
    cumulativeGasUsed : Nat;
  };

  public type RpcError = {
    #ProviderError : { code : Int32; message : Text };
    #HttpOutcallError : { code : Int32; message : Text };
    #JsonRpcError : { code : Int64; message : Text };
    #ValidationError : Text;
  };

  // ── Service variants ──

  public type EthMainnetService = {
    #Alchemy; #Ankr; #BlockPi; #Cloudflare; #PublicNode; #Llama;
  };

  public type EthSepoliaService = {
    #Alchemy; #Ankr; #BlockPi; #PublicNode; #Sepolia;
  };

  public type L2MainnetService = {
    #Alchemy; #Ankr; #BlockPi; #PublicNode; #Llama;
  };

  public type RpcApi = {
    url : Text;
    headers : ?[{ name : Text; value : Text }];
  };

  public type RpcServices = {
    #Custom : { chainId : Nat64; services : [RpcApi] };
    #EthSepolia : ?[EthSepoliaService];
    #EthMainnet : ?[EthMainnetService];
    #ArbitrumOne : ?[L2MainnetService];
    #BaseMainnet : ?[L2MainnetService];
    #OptimismMainnet : ?[L2MainnetService];
  };

  public type RpcService = {
    #Provider : Nat64;
    #Custom : RpcApi;
    #EthSepolia : EthSepoliaService;
    #EthMainnet : EthMainnetService;
    #ArbitrumOne : L2MainnetService;
    #BaseMainnet : L2MainnetService;
    #OptimismMainnet : L2MainnetService;
  };

  public type ConsensusStrategy = {
    #Equality;
    #Threshold : { total : ?Nat8; min : Nat8 };
  };

  public type RpcConfig = {
    responseSizeEstimate : ?Nat64;
    responseConsensus : ?ConsensusStrategy;
  };

  // ── Transaction receipt ──

  public type GetTransactionReceiptResult = {
    #Ok : ?TransactionReceipt;
    #Err : RpcError;
  };

  public type MultiGetTransactionReceiptResult = {
    #Consistent : GetTransactionReceiptResult;
    #Inconsistent : [(RpcService, GetTransactionReceiptResult)];
  };

  // ── Transaction count (nonce) ──

  public type BlockTag = {
    #Earliest; #Safe; #Finalized; #Latest; #Number : Nat; #Pending;
  };

  public type GetTransactionCountArgs = {
    address : Text;
    block : BlockTag;
  };

  public type GetTransactionCountResult = {
    #Ok : Nat;
    #Err : RpcError;
  };

  public type MultiGetTransactionCountResult = {
    #Consistent : GetTransactionCountResult;
    #Inconsistent : [(RpcService, GetTransactionCountResult)];
  };

  // ── Send raw transaction ──

  public type SendRawTransactionStatus = {
    #Ok : ?Text;
    #NonceTooLow;
    #NonceTooHigh;
    #InsufficientFunds;
  };

  public type SendRawTransactionResult = {
    #Ok : SendRawTransactionStatus;
    #Err : RpcError;
  };

  public type MultiSendRawTransactionResult = {
    #Consistent : SendRawTransactionResult;
    #Inconsistent : [(RpcService, SendRawTransactionResult)];
  };

  // ── Fee history ──

  public type FeeHistoryArgs = {
    blockCount : Nat;
    newestBlock : BlockTag;
    rewardPercentiles : ?[Nat8];
  };

  public type FeeHistory = {
    reward : [[Nat]];
    gasUsedRatio : [Float];
    oldestBlock : Nat;
    baseFeePerGas : [Nat];
  };

  public type FeeHistoryResult = {
    #Ok : FeeHistory;
    #Err : RpcError;
  };

  public type MultiFeeHistoryResult = {
    #Consistent : FeeHistoryResult;
    #Inconsistent : [(RpcService, FeeHistoryResult)];
  };

  // ═══════════════════════════════════════════════════════════════════════
  // Actor interface
  // ═══════════════════════════════════════════════════════════════════════

  public type EvmRpcCanister = actor {
    eth_getTransactionReceipt : (RpcServices, ?RpcConfig, Text) -> async MultiGetTransactionReceiptResult;
    eth_getTransactionCount : (RpcServices, ?RpcConfig, GetTransactionCountArgs) -> async MultiGetTransactionCountResult;
    eth_sendRawTransaction : (RpcServices, ?RpcConfig, Text) -> async MultiSendRawTransactionResult;
    eth_feeHistory : (RpcServices, ?RpcConfig, FeeHistoryArgs) -> async MultiFeeHistoryResult;
  };

  // ═══════════════════════════════════════════════════════════════════════
  // Constants
  // ═══════════════════════════════════════════════════════════════════════

  /// Default EVM RPC Canister principal (mainnet).
  public let DEFAULT_CANISTER : Text = "7hfb6-caaaa-aaaar-qadga-cai";

  /// Cycles to attach for EVM RPC calls (10 billion).
  public let RPC_CYCLES : Nat = 10_000_000_000;

  // ═══════════════════════════════════════════════════════════════════════
  // Chain mapping
  // ═══════════════════════════════════════════════════════════════════════

  /// Map a chain ID to the appropriate RpcServices variant.
  public func rpcServices(chainId : Nat) : ?RpcServices {
    // Ethereum Mainnet
    if (chainId == 1) { return ?#EthMainnet(null) };
    // Base Mainnet
    if (chainId == 8453) { return ?#BaseMainnet(null) };
    // Optimism Mainnet
    if (chainId == 10) { return ?#OptimismMainnet(null) };
    // Arbitrum One
    if (chainId == 42161) { return ?#ArbitrumOne(null) };
    // Ethereum Sepolia
    if (chainId == 11155111) { return ?#EthSepolia(null) };

    // Avalanche C-Chain (mainnet + testnet)
    if (chainId == 43114) {
      return ?#Custom({
        chainId = 43114 : Nat64;
        services = [{
          url = "https://api.avax.network/ext/bc/C/rpc";
          headers = null;
        }, {
          url = "https://avalanche-c-chain-rpc.publicnode.com";
          headers = null;
        }, {
          url = "https://avax.meowrpc.com";
          headers = null;
        }];
      });
    };
    if (chainId == 43113) {
      return ?#Custom({
        chainId = 43113 : Nat64;
        services = [{
          url = "https://api.avax-test.network/ext/bc/C/rpc";
          headers = null;
        }, {
          url = "https://avalanche-fuji-c-chain-rpc.publicnode.com";
          headers = null;
        }];
      });
    };

    // Testnet L2s
    if (chainId == 84532) {
      return ?#Custom({
        chainId = 84532 : Nat64;
        services = [{
          url = "https://sepolia.base.org";
          headers = null;
        }, {
          url = "https://base-sepolia-rpc.publicnode.com";
          headers = null;
        }];
      });
    };
    if (chainId == 11155420) {
      return ?#Custom({
        chainId = 11155420 : Nat64;
        services = [{
          url = "https://sepolia.optimism.io";
          headers = null;
        }, {
          url = "https://optimism-sepolia-rpc.publicnode.com";
          headers = null;
        }];
      });
    };
    if (chainId == 421614) {
      return ?#Custom({
        chainId = 421614 : Nat64;
        services = [{
          url = "https://sepolia-rollup.arbitrum.io/rpc";
          headers = null;
        }, {
          url = "https://arbitrum-sepolia-rpc.publicnode.com";
          headers = null;
        }];
      });
    };

    null;
  };

  /// Format an RpcError as human-readable text.
  public func rpcErrorToText(err : RpcError) : Text {
    switch (err) {
      case (#ProviderError({ message })) { "Provider: " # message };
      case (#HttpOutcallError({ message })) { "HTTP outcall: " # message };
      case (#JsonRpcError({ message })) { "JSON-RPC: " # message };
      case (#ValidationError(msg)) { "Validation: " # msg };
    };
  };
};
