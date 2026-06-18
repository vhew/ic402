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

  /// EVM log entry from transaction receipt.
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

  /// EVM transaction receipt.
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

  /// EVM RPC error — a FAITHFUL mirror of evm_rpc.did's RpcError. These types MUST match the
  /// canister's wire types exactly: a multi-provider response is Candid-decoded WHOLE before our
  /// consensus logic ever runs, so if ANY single provider returns ProviderError / HttpOutcallError
  /// / ValidationError (all of which are VARIANTS on the wire, not flat {code;message} records) the
  /// entire decode TRAPS when the arm is mis-typed. That is exactly what made openSession fail with
  /// "unexpected IDL type when parsing {code : Int32; message : Text}" whenever a provider hit a
  /// transient JSON-RPC / HTTP-outcall error — even though 2-of-3 consensus would otherwise tolerate it.
  public type RejectionCode = {
    #NoError;
    #SysFatal;
    #SysTransient;
    #DestinationInvalid;
    #CanisterReject;
    #CanisterError;
    #Unknown;
  };

  public type ProviderError = {
    #TooFewCycles : { expected : Nat; received : Nat };
    #MissingRequiredProvider;
    #ProviderNotFound;
    #NoPermission;
    #InvalidRpcConfig : Text;
  };

  public type ValidationError = {
    #Custom : Text;
    #InvalidHex : Text;
  };

  public type HttpOutcallError = {
    #IcError : { code : RejectionCode; message : Text };
    #InvalidHttpJsonRpcResponse : { status : Nat16; body : Text; parsingError : ?Text };
  };

  public type JsonRpcError = { code : Int64; message : Text };

  public type RpcError = {
    #JsonRpcError : JsonRpcError;
    #ProviderError : ProviderError;
    #ValidationError : ValidationError;
    #HttpOutcallError : HttpOutcallError;
  };

  // ── Service variants ──

  /// Ethereum mainnet RPC service endpoints.
  public type EthMainnetService = {
    #Alchemy; #Ankr; #BlockPi; #Cloudflare; #PublicNode; #Llama;
  };

  /// Ethereum Sepolia testnet RPC service endpoints.
  public type EthSepoliaService = {
    #Alchemy; #Ankr; #BlockPi; #PublicNode; #Sepolia;
  };

  /// Layer-2 mainnet RPC service endpoints (Base, Optimism, Arbitrum).
  public type L2MainnetService = {
    #Alchemy; #Ankr; #BlockPi; #PublicNode; #Llama;
  };

  /// Custom RPC endpoint with URL and optional headers.
  public type RpcApi = {
    url : Text;
    headers : ?[{ name : Text; value : Text }];
  };

  /// Multi-provider RPC service selection for a chain.
  public type RpcServices = {
    #Custom : { chainId : Nat64; services : [RpcApi] };
    #EthSepolia : ?[EthSepoliaService];
    #EthMainnet : ?[EthMainnetService];
    #ArbitrumOne : ?[L2MainnetService];
    #BaseMainnet : ?[L2MainnetService];
    #OptimismMainnet : ?[L2MainnetService];
  };

  /// Single RPC service endpoint selector.
  public type RpcService = {
    #Provider : Nat64;
    #Custom : RpcApi;
    #EthSepolia : EthSepoliaService;
    #EthMainnet : EthMainnetService;
    #ArbitrumOne : L2MainnetService;
    #BaseMainnet : L2MainnetService;
    #OptimismMainnet : L2MainnetService;
  };

  /// Multi-provider consensus strategy for RPC responses.
  public type ConsensusStrategy = {
    #Equality;
    #Threshold : { total : ?Nat8; min : Nat8 };
  };

  /// Configuration for EVM RPC requests (response size, consensus).
  public type RpcConfig = {
    responseSizeEstimate : ?Nat64;
    responseConsensus : ?ConsensusStrategy;
  };

  // ── Transaction receipt ──

  /// Result of a single-provider transaction receipt query.
  public type GetTransactionReceiptResult = {
    #Ok : ?TransactionReceipt;
    #Err : RpcError;
  };

  /// Multi-provider consensus result for transaction receipt queries.
  public type MultiGetTransactionReceiptResult = {
    #Consistent : GetTransactionReceiptResult;
    #Inconsistent : [(RpcService, GetTransactionReceiptResult)];
  };

  // ── Transaction count (nonce) ──

  /// Ethereum block reference tag.
  public type BlockTag = {
    #Earliest; #Safe; #Finalized; #Latest; #Number : Nat; #Pending;
  };

  /// Arguments for eth_getTransactionCount (nonce query).
  public type GetTransactionCountArgs = {
    address : Text;
    block : BlockTag;
  };

  /// Result of a single-provider transaction count query.
  public type GetTransactionCountResult = {
    #Ok : Nat;
    #Err : RpcError;
  };

  /// Multi-provider consensus result for transaction count queries.
  public type MultiGetTransactionCountResult = {
    #Consistent : GetTransactionCountResult;
    #Inconsistent : [(RpcService, GetTransactionCountResult)];
  };

  // ── Send raw transaction ──

  /// Status of a raw transaction submission.
  public type SendRawTransactionStatus = {
    #Ok : ?Text;
    #NonceTooLow;
    #NonceTooHigh;
    #InsufficientFunds;
  };

  /// Result of a single-provider raw transaction submission.
  public type SendRawTransactionResult = {
    #Ok : SendRawTransactionStatus;
    #Err : RpcError;
  };

  /// Multi-provider consensus result for raw transaction submissions.
  public type MultiSendRawTransactionResult = {
    #Consistent : SendRawTransactionResult;
    #Inconsistent : [(RpcService, SendRawTransactionResult)];
  };

  // ── Fee history ──

  /// Arguments for eth_feeHistory query.
  public type FeeHistoryArgs = {
    blockCount : Nat;
    newestBlock : BlockTag;
    rewardPercentiles : ?[Nat8];
  };

  /// EVM fee history data (base fees, gas ratios, rewards).
  public type FeeHistory = {
    reward : [[Nat]];
    gasUsedRatio : [Float];
    oldestBlock : Nat;
    baseFeePerGas : [Nat];
  };

  /// Result of a single-provider fee history query.
  public type FeeHistoryResult = {
    #Ok : FeeHistory;
    #Err : RpcError;
  };

  /// Multi-provider consensus result for fee history queries.
  public type MultiFeeHistoryResult = {
    #Consistent : FeeHistoryResult;
    #Inconsistent : [(RpcService, FeeHistoryResult)];
  };

  // ═══════════════════════════════════════════════════════════════════════
  // Actor interface
  // ═══════════════════════════════════════════════════════════════════════

  /// Actor interface for the DFINITY EVM RPC Canister.
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
        }, {
          // NEW-4: a 3rd provider so 2-of-3 responseConsensus tolerates ONE flaky/down RPC.
          // With 2-of-2 a single failing provider parked every settle/close on this chain.
          // (Security is unchanged: receipts still need 2 providers to AGREE, just not these 2.)
          url = "https://avalanche-fuji.drpc.org";
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
        }, {
          url = "https://base-sepolia.drpc.org"; // NEW-4: 3rd provider → 2-of-3 resilience
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
        }, {
          url = "https://optimism-sepolia.drpc.org"; // NEW-4: 3rd provider → 2-of-3 resilience
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
        }, {
          url = "https://arbitrum-sepolia.drpc.org"; // NEW-4: 3rd provider → 2-of-3 resilience
          headers = null;
        }];
      });
    };

    null;
  };

  /// Format an RpcError as human-readable text.
  public func rpcErrorToText(err : RpcError) : Text {
    switch (err) {
      case (#JsonRpcError({ message })) { "JSON-RPC: " # message };
      case (#ProviderError(pe)) {
        switch (pe) {
          case (#TooFewCycles(_)) { "Provider: too few cycles" };
          case (#MissingRequiredProvider) { "Provider: missing required provider" };
          case (#ProviderNotFound) { "Provider: provider not found" };
          case (#NoPermission) { "Provider: no permission" };
          case (#InvalidRpcConfig(m)) { "Provider: invalid RPC config: " # m };
        };
      };
      case (#ValidationError(ve)) {
        switch (ve) {
          case (#Custom(m)) { "Validation: " # m };
          case (#InvalidHex(m)) { "Validation: invalid hex: " # m };
        };
      };
      case (#HttpOutcallError(he)) {
        switch (he) {
          case (#IcError({ message })) { "HTTP outcall: " # message };
          case (#InvalidHttpJsonRpcResponse({ body })) { "HTTP outcall: invalid JSON-RPC response: " # body };
        };
      };
    };
  };
};
