/// ic402 — EVM transaction verification via the DFINITY EVM RPC Canister.
///
// Verifies ERC-20 transfers on any supported EVM chain by calling
// eth_getTransactionReceipt through the EVM RPC Canister (7hfb6-caaaa-aaaar-qadga-cai),
// which proxies JSON-RPC calls to multiple providers with consensus verification.
///
// Supports Ethereum, Avalanche, Base, Optimism, and Arbitrum (mainnet + testnet).
///
// Used by Gateway.settle() when the payment network is "eip155:*".

import Text "mo:base/Text";
import Nat "mo:base/Nat";
import Nat32 "mo:base/Nat32";
import Array "mo:base/Array";
import Iter "mo:base/Iter";
import Char "mo:base/Char";
import EvmAddress "EvmAddress";
import EvmRpc "EvmRpc";

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

  // ── EVM RPC types (re-exported from EvmRpc for backward compat) ──

  /// Re-export: LogEntry from EvmRpc.
  public type LogEntry = EvmRpc.LogEntry;
  /// Re-export: TransactionReceipt from EvmRpc.
  public type TransactionReceipt = EvmRpc.TransactionReceipt;
  /// Re-export: RpcError from EvmRpc.
  public type RpcError = EvmRpc.RpcError;
  /// Re-export: GetTransactionReceiptResult from EvmRpc.
  public type GetTransactionReceiptResult = EvmRpc.GetTransactionReceiptResult;
  /// Re-export: EthMainnetService from EvmRpc.
  public type EthMainnetService = EvmRpc.EthMainnetService;
  /// Re-export: EthSepoliaService from EvmRpc.
  public type EthSepoliaService = EvmRpc.EthSepoliaService;
  /// Re-export: L2MainnetService from EvmRpc.
  public type L2MainnetService = EvmRpc.L2MainnetService;
  /// Re-export: RpcApi from EvmRpc.
  public type RpcApi = EvmRpc.RpcApi;
  /// Re-export: RpcServices from EvmRpc.
  public type RpcServices = EvmRpc.RpcServices;
  /// Re-export: RpcService from EvmRpc.
  public type RpcService = EvmRpc.RpcService;
  /// Re-export: ConsensusStrategy from EvmRpc.
  public type ConsensusStrategy = EvmRpc.ConsensusStrategy;
  /// Re-export: RpcConfig from EvmRpc.
  public type RpcConfig = EvmRpc.RpcConfig;
  /// Re-export: MultiGetTransactionReceiptResult from EvmRpc.
  public type MultiGetTransactionReceiptResult = EvmRpc.MultiGetTransactionReceiptResult;
  /// Re-export: EvmRpcCanister from EvmRpc.
  public type EvmRpcService = EvmRpc.EvmRpcCanister;

  /// Default EVM RPC Canister principal (mainnet).
  public let DEFAULT_EVM_RPC_CANISTER : Text = EvmRpc.DEFAULT_CANISTER;

  // ERC-20 Transfer event topic: keccak256("Transfer(address,address,uint256)")
  // Computed dynamically to avoid hardcoded hash errors.
  func transferTopic() : Text {
    EvmAddress.toHex(EvmAddress.keccak256Text("Transfer(address,address,uint256)"));
  };

  let RPC_CYCLES : Nat = EvmRpc.RPC_CYCLES;

  // Map a chain ID to the appropriate RpcServices variant.
  func rpcServices(chainId : Nat) : ?RpcServices {
    EvmRpc.rpcServices(chainId);
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
      // H-3: Reject inconsistent responses entirely — cannot verify safely
      case (#Inconsistent(_)) {
        return #failed("Inconsistent RPC responses — cannot verify safely");
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
    switch (findTransferLog(receipt.logs, normalizedExpected, normalizedRecipient)) {
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
  /// where the log is from the expected token contract and the
  /// recipient (topics[2]) matches expectedRecipient.
  /// Returns (recipientAddress, amount) if found.
  public func findTransferLog(logs : [LogEntry], expectedToken : Text, expectedRecipient : Text) : ?(Text, Nat) {
    for (log in logs.vals()) {
      // C-2: Only consider logs from the expected token contract
      if (toLower(log.address) != expectedToken) {
        // skip — this log is from a different contract
      } else if (log.topics.size() >= 3) {
        let topic0 = toLower(log.topics[0]);
        if (topic0 == transferTopic()) {
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
  public func hexToAddress(hex : Text) : Text {
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
  public func hexToNat(hex : Text) : Nat {
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
  public func toLower(t : Text) : Text {
    Text.map(t, func(c : Char) : Char {
      if (c >= 'A' and c <= 'Z') {
        Char.fromNat32(Char.toNat32(c) + 32);
      } else { c };
    });
  };

  func rpcErrorToText(err : RpcError) : Text {
    EvmRpc.rpcErrorToText(err);
  };

};
