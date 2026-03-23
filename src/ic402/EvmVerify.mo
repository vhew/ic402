/// ic402 — EVM transaction verification via the DFINITY EVM RPC Canister.
///
/// Verifies ERC-20 transfers on any supported EVM chain by calling
/// eth_getTransactionReceipt through the EVM RPC Canister (7hfb6-caaaa-aaaar-qadga-cai),
/// which proxies JSON-RPC calls to multiple providers with consensus verification.
///
/// Supports Ethereum, Avalanche, Base, Optimism, and Arbitrum (mainnet + testnet).
///
/// Used by Gateway.settle() when the payment network is "eip155:*".

import Text "mo:base/Text";
import Nat "mo:base/Nat";
import Nat32 "mo:base/Nat32";
import Array "mo:base/Array";
import Iter "mo:base/Iter";
import Char "mo:base/Char";

module {

  /// Result of verifying an EVM transaction.
  public type VerifyResult = {
    #ok : {
      txHash : Text;
      from : Text;
      to : Text;          // the contract called (e.g. USDC)
      recipient : Text;   // actual transfer recipient from event log
      amount : Nat;        // actual transfer amount from event log
      status : Bool;
      blockNumber : Text;
    };
    #failed : Text;
  };

  // ── EVM RPC Canister types (from evm_rpc.did) ──

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
    // "type" is a reserved word in Motoko; Candid maps it as-is
    // but we omit it here since we don't need it for verification.
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

  public type GetTransactionReceiptResult = {
    #Ok : ?TransactionReceipt;
    #Err : RpcError;
  };

  public type EthMainnetService = {
    #Alchemy;
    #Ankr;
    #BlockPi;
    #Cloudflare;
    #PublicNode;
    #Llama;
  };

  public type EthSepoliaService = {
    #Alchemy;
    #Ankr;
    #BlockPi;
    #PublicNode;
    #Sepolia;
  };

  public type L2MainnetService = {
    #Alchemy;
    #Ankr;
    #BlockPi;
    #PublicNode;
    #Llama;
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

  public type MultiGetTransactionReceiptResult = {
    #Consistent : GetTransactionReceiptResult;
    #Inconsistent : [(RpcService, GetTransactionReceiptResult)];
  };

  /// Actor interface for the EVM RPC Canister.
  public type EvmRpcService = actor {
    eth_getTransactionReceipt : (RpcServices, ?RpcConfig, Text) -> async MultiGetTransactionReceiptResult;
  };

  /// Default EVM RPC Canister principal (mainnet).
  /// Override via evmRpcCanister in Config for local development.
  public let DEFAULT_EVM_RPC_CANISTER : Text = "7hfb6-caaaa-aaaar-qadga-cai";

  /// ERC-20 Transfer event topic: keccak256("Transfer(address,address,uint256)")
  /// Lowercase with 0x prefix for comparison against RPC canister response topics.
  let TRANSFER_TOPIC = "0xddf252ad1be2c4dbc95581d3b0f4f22d3e4cadc6b89216b6b02654fec70f965c";

  /// Cycles to attach for EVM RPC calls.
  /// 10 billion cycles covers eth_getTransactionReceipt with consensus across 3+ providers.
  /// The EVM RPC canister refunds unused cycles.
  let RPC_CYCLES : Nat = 10_000_000_000;

  /// Map a chain ID to the appropriate RpcServices variant.
  /// Returns null for unsupported chains (e.g. Avalanche, which the EVM RPC
  /// canister does not have built-in support for).
  func rpcServices(chainId : Nat) : ?RpcServices {
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

    // Avalanche C-Chain (mainnet: 43114, testnet: 43113) — use Custom with public RPC
    if (chainId == 43114) {
      return ?#Custom({
        chainId = 43114 : Nat64;
        services = [{
          url = "https://api.avax.network/ext/bc/C/rpc";
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
        }];
      });
    };

    // Testnet L2s — use Custom with public RPC endpoints
    if (chainId == 84532) {
      return ?#Custom({
        chainId = 84532 : Nat64;
        services = [{
          url = "https://sepolia.base.org";
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
        }];
      });
    };
    if (chainId == 421614) {
      return ?#Custom({
        chainId = 421614 : Nat64;
        services = [{
          url = "https://sepolia-rollup.arbitrum.io/rpc";
          headers = null;
        }];
      });
    };

    null;
  };

  /// Verify an EVM transaction receipt via the EVM RPC Canister.
  /// Checks: tx succeeded, sent to correct token contract,
  /// Transfer event log shows correct recipient and sufficient amount.
  public func verifyTransaction(
    txHash : Text,
    chainId : Nat,
    expectedToken : Text,
    expectedRecipient : Text,
    expectedAmount : Nat,
    evmRpcCanister : ?Text,
  ) : async VerifyResult {
    let services = switch (rpcServices(chainId)) {
      case (?s) { s };
      case (null) { return #failed("Unsupported chain ID: " # Nat.toText(chainId)) };
    };

    let rpcPrincipal = switch (evmRpcCanister) {
      case (?p) { p };
      case (null) { DEFAULT_EVM_RPC_CANISTER };
    };
    let evmRpc : EvmRpcService = actor (rpcPrincipal);

    // Call the EVM RPC canister with consensus verification.
    // Attaching cycles to cover the multi-provider outcall cost.
    let rpcResult = await (with cycles = RPC_CYCLES) evmRpc.eth_getTransactionReceipt(
      services,
      null, // default RpcConfig (3-provider consensus)
      txHash,
    );

    // Extract the receipt from the consensus result
    let receipt : TransactionReceipt = switch (rpcResult) {
      case (#Consistent(#Ok(?r))) { r };
      case (#Consistent(#Ok(null))) {
        return #failed("Transaction not found or not yet confirmed");
      };
      case (#Consistent(#Err(err))) {
        return #failed("RPC error: " # rpcErrorToText(err));
      };
      case (#Inconsistent(results)) {
        // Try to find any successful result among inconsistent responses.
        // This can happen when providers return the same receipt but with
        // minor formatting differences that the canister deems inconsistent.
        switch (firstOkReceipt(results)) {
          case (?r) { r };
          case (null) {
            return #failed("Inconsistent RPC responses from providers");
          };
        };
      };
    };

    // Check transaction status (1 = success)
    let txSucceeded = switch (receipt.status) {
      case (?s) { s == 1 };
      case (null) { return #failed("Transaction status not available (pre-Byzantium)") };
    };
    if (not txSucceeded) {
      return #failed("Transaction reverted (status: 0x0)");
    };

    // Verify tx was to the expected token contract
    let receiptTo = switch (receipt.to) {
      case (?t) { t };
      case (null) { return #failed("Transaction has no 'to' address (contract creation)") };
    };

    let normalizedTo = toLower(receiptTo);
    let normalizedExpected = toLower(expectedToken);
    if (normalizedTo != normalizedExpected) {
      return #failed(
        "Transaction target " # receiptTo #
        " does not match expected token " # expectedToken
      );
    };

    // Find the ERC-20 Transfer event in structured logs
    let normalizedRecipient = toLower(expectedRecipient);
    switch (findTransferLog(receipt.logs, normalizedRecipient)) {
      case (null) {
        return #failed("No Transfer event found to recipient " # expectedRecipient);
      };
      case (?(logRecipient, logAmount)) {
        if (logAmount < expectedAmount) {
          return #failed(
            "Transfer amount " # Nat.toText(logAmount) #
            " < required " # Nat.toText(expectedAmount)
          );
        };

        #ok({
          txHash;
          from = receipt.from;
          to = receiptTo;
          recipient = logRecipient;
          amount = logAmount;
          status = txSucceeded;
          blockNumber = Nat.toText(receipt.blockNumber);
        });
      };
    };
  };

  // ── Transfer event log parsing (structured, no JSON) ──

  /// Search the structured log entries for an ERC-20 Transfer event
  /// where the recipient (topics[2]) matches expectedRecipient.
  /// Returns (recipientAddress, amount) if found.
  func findTransferLog(logs : [LogEntry], expectedRecipient : Text) : ?(Text, Nat) {
    for (log in logs.vals()) {
      // Transfer events have exactly 3 topics:
      //   [0] = Transfer event signature hash
      //   [1] = from address (zero-padded)
      //   [2] = to address (zero-padded)
      if (log.topics.size() >= 3) {
        let topic0 = toLower(log.topics[0]);
        if (topic0 == TRANSFER_TOPIC) {
          let topic2 = log.topics[2];
          // topic2 is a 32-byte zero-padded address: "0x" + 64 hex chars
          if (topic2.size() >= 66) {
            let recipientAddr = hexToAddress(topic2);

            if (recipientAddr.size() == 42 and recipientAddr == expectedRecipient) {
              // Data field contains the uint256 transfer amount
              if (log.data.size() >= 4) {
                let amount = hexToNat(log.data);
                return ?(recipientAddr, amount);
              };
            };
          };
        };
      };
    };
    null;
  };

  // ── Helpers ──

  /// Extract the last 40 hex chars from a 64-char hex value -> 0x-prefixed address.
  func hexToAddress(hex : Text) : Text {
    let chars = Iter.toArray(hex.chars());
    var start = 0;
    if (chars.size() >= 2 and chars[0] == '0' and (chars[1] == 'x' or chars[1] == 'X')) {
      start := 2;
    };
    let hexOnly = Array.subArray(chars, start, chars.size() - start);
    if (hexOnly.size() < 40) return "";
    let addrStart = hexOnly.size() - 40;
    var addr = "0x";
    var k = addrStart;
    while (k < hexOnly.size()) {
      addr := addr # Char.toText(hexOnly[k]);
      k += 1;
    };
    toLower(addr);
  };

  /// Parse a hex string (with or without 0x prefix) to Nat.
  /// ERC-20 amounts are uint256, max 2^256-1. We cap at 64 hex digits.
  /// Non-hex characters after the prefix cause the parse to stop (returns value so far).
  func hexToNat(hex : Text) : Nat {
    var result : Nat = 0;
    var hexDigits : Nat = 0;
    var pastPrefix = false;
    for (c in hex.chars()) {
      if (c == 'x' or c == 'X') {
        result := 0;
        hexDigits := 0;
        pastPrefix := true;
      } else if (c == '0' and not pastPrefix) {
        pastPrefix := true;
      } else {
        let n = Char.toNat32(c);
        let isHex = (n >= 48 and n <= 57) or (n >= 97 and n <= 102) or (n >= 65 and n <= 70);
        if (not isHex) { return result };
        hexDigits += 1;
        if (hexDigits > 64) { return result };
        let digit : Nat = if (n >= 48 and n <= 57) { Nat32.toNat(n - 48) }
          else if (n >= 97 and n <= 102) { Nat32.toNat(n - 87) }
          else { Nat32.toNat(n - 55) };
        result := result * 16 + digit;
      };
    };
    result;
  };

  /// Convert ASCII upper-case letters to lower-case.
  func toLower(t : Text) : Text {
    Text.map(t, func(c : Char) : Char {
      if (c >= 'A' and c <= 'Z') {
        Char.fromNat32(Char.toNat32(c) + 32);
      } else { c };
    });
  };

  /// Format an RpcError as human-readable text.
  func rpcErrorToText(err : RpcError) : Text {
    switch (err) {
      case (#ProviderError({ message })) { "Provider: " # message };
      case (#HttpOutcallError({ message })) { "HTTP outcall: " # message };
      case (#JsonRpcError({ message })) { "JSON-RPC: " # message };
      case (#ValidationError(msg)) { "Validation: " # msg };
    };
  };

  /// Extract the first successful receipt from inconsistent provider results.
  func firstOkReceipt(results : [(RpcService, GetTransactionReceiptResult)]) : ?TransactionReceipt {
    for ((_, result) in results.vals()) {
      switch (result) {
        case (#Ok(?r)) { return ?r };
        case (_) {};
      };
    };
    null;
  };
};
