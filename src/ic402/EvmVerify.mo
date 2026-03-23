/// ic402 — EVM transaction verification via HTTPS outcalls.
///
/// Verifies ERC-20 transfers on any supported EVM chain by calling
/// eth_getTransactionReceipt and decoding the Transfer event log.
/// Supports Ethereum, Avalanche, Base, Optimism, and Arbitrum.
///
/// Used by Gateway.settle() when the payment network is "eip155:*".

import Text "mo:base/Text";
import Nat "mo:base/Nat";
import Nat8 "mo:base/Nat8";
import Nat32 "mo:base/Nat32";
import Blob "mo:base/Blob";
import Array "mo:base/Array";
import Iter "mo:base/Iter";
import Char "mo:base/Char";
import IC "mo:ic";

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

  /// ERC-20 Transfer event topic: keccak256("Transfer(address,address,uint256)")
  let TRANSFER_TOPIC = "ddf252ad1be2c4dbc95581d3b0f4f22d3e4cadc6b89216b6b02654fec70f965c";

  /// RPC endpoints by chain ID (mainnet + testnet).
  public func rpcUrl(chainId : Nat) : Text {
    if (chainId == 1)          { "https://ethereum-rpc.publicnode.com" }
    else if (chainId == 43114) { "https://api.avax.network/ext/bc/C/rpc" }
    else if (chainId == 8453)  { "https://mainnet.base.org" }
    else if (chainId == 10)    { "https://mainnet.optimism.io" }
    else if (chainId == 42161) { "https://arb1.arbitrum.io/rpc" }
    else if (chainId == 11155111) { "https://ethereum-sepolia-rpc.publicnode.com" }
    else if (chainId == 43113)    { "https://api.avax-test.network/ext/bc/C/rpc" }
    else if (chainId == 84532)    { "https://sepolia.base.org" }
    else if (chainId == 11155420) { "https://sepolia.optimism.io" }
    else if (chainId == 421614)   { "https://sepolia-rollup.arbitrum.io/rpc" }
    else { "https://ethereum-rpc.publicnode.com" };
  };

  let QUOTE : Char = '\"';
  let ic : IC.Service = actor "aaaaa-aa";

  /// Verify an EVM transaction receipt via HTTPS outcall.
  /// Checks: tx succeeded, sent to correct token contract,
  /// Transfer event log shows correct recipient and sufficient amount.
  public func verifyTransaction(
    txHash : Text,
    chainId : Nat,
    expectedToken : Text,
    expectedRecipient : Text,
    expectedAmount : Nat,
  ) : async VerifyResult {
    let url = rpcUrl(chainId);

    let body = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"eth_getTransactionReceipt\",\"params\":[\"" # txHash # "\"]}";

    // Increase max response to capture logs
    let response = await (with cycles = 230_000_000_000) ic.http_request({
      url = url;
      method = #post;
      max_response_bytes = ?50_000;
      body = ?Text.encodeUtf8(body);
      headers = [
        { name = "Content-Type"; value = "application/json" },
      ];
      transform = null;
    });

    if (response.status != 200) {
      return #failed("RPC returned status " # Nat.toText(response.status));
    };

    let responseText = switch (Text.decodeUtf8(response.body)) {
      case (?t) { t };
      case (null) { return #failed("Invalid UTF-8 in RPC response") };
    };

    let status = extractJsonField(responseText, "status");
    let to = extractJsonField(responseText, "to");
    let from = extractJsonField(responseText, "from");
    let blockNumber = extractJsonField(responseText, "blockNumber");

    if (status == "") {
      return #failed("Transaction not found or not yet confirmed");
    };

    let txSucceeded = status == "0x1";
    if (not txSucceeded) {
      return #failed("Transaction reverted (status: " # status # ")");
    };

    // Verify tx was to the expected token contract
    let normalizedTo = toLower(to);
    let normalizedExpected = toLower(expectedToken);
    if (normalizedTo != normalizedExpected) {
      return #failed("Transaction target " # to # " does not match expected token " # expectedToken);
    };

    // Decode ERC-20 Transfer event from logs
    let normalizedRecipient = toLower(expectedRecipient);
    switch (findTransferLog(responseText, normalizedRecipient)) {
      case (null) {
        return #failed("No Transfer event found to recipient " # expectedRecipient);
      };
      case (?(logRecipient, logAmount)) {
        if (logAmount < expectedAmount) {
          return #failed("Transfer amount " # Nat.toText(logAmount) # " < required " # Nat.toText(expectedAmount));
        };

        #ok({
          txHash;
          from;
          to;
          recipient = logRecipient;
          amount = logAmount;
          status = txSucceeded;
          blockNumber;
        });
      };
    };
  };

  // ── Transfer event log parsing ──

  /// Search the JSON-RPC receipt response for a Transfer event log
  /// where the recipient (topics[2]) matches expectedRecipient.
  /// Returns (recipientAddress, amount) if found.
  func findTransferLog(responseText : Text, expectedRecipient : Text) : ?(Text, Nat) {
    // Strategy: find the Transfer event topic hash in the response,
    // then extract topics[2] (recipient) and "data" (amount) from
    // the surrounding log entry.
    let chars = Iter.toArray(responseText.chars());
    let len = chars.size();
    let topicChars = Iter.toArray(TRANSFER_TOPIC.chars());
    let topicLen = topicChars.size();

    var i = 0;
    while (i + topicLen < len) {
      // Look for the Transfer topic hash (without 0x prefix)
      var match = true;
      var j = 0;
      while (j < topicLen) {
        let c = if (chars[i + j] >= 'A' and chars[i + j] <= 'Z') {
          Char.fromNat32(Char.toNat32(chars[i + j]) + 32)
        } else { chars[i + j] };
        if (c != topicChars[j]) {
          match := false;
          j := topicLen;
        } else {
          j += 1;
        };
      };

      if (match) {
        // Found the Transfer topic. Extract a window around it for parsing.
        // Look back up to 200 chars and forward up to 1000 chars for the log context.
        let windowStart = if (i > 200) { i - 200 } else { 0 };
        let windowEnd = if (i + 1000 < len) { i + 1000 } else { len };
        let window = textSlice(chars, windowStart, windowEnd);

        // Extract topics array entries after the Transfer topic
        // In JSON: "topics":["0x<transfer>","0x<from>","0x<to>"]
        // Find the next two 0x-prefixed 66-char hex values after our match position
        let afterMatch = textSlice(chars, i + topicLen, windowEnd);

        // Skip past topics[0] closing quote, find topics[1] (from), then topics[2] (to)
        let topic1 = extractNextQuotedHex(afterMatch);
        let afterTopic1 = textAfter(afterMatch, topic1);
        let topic2 = extractNextQuotedHex(afterTopic1);

        // topic2 is the recipient address (last 40 chars of 64-char padded value)
        let recipientAddr = hexToAddress(topic2);

        if (recipientAddr == expectedRecipient) {
          // Find the "data" field in this log entry for the amount
          let dataHex = extractJsonField(window, "data");
          let amount = hexToNat(dataHex);
          return ?(recipientAddr, amount);
        };
      };
      i += 1;
    };
    null;
  };

  /// Extract the last 40 hex chars from a 64-char hex value → 0x-prefixed address.
  func hexToAddress(hex : Text) : Text {
    let chars = Iter.toArray(hex.chars());
    // Remove 0x prefix if present, then take last 40 chars
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
  func hexToNat(hex : Text) : Nat {
    var result : Nat = 0;
    var started = false;
    for (c in hex.chars()) {
      if (c == 'x' or c == 'X') {
        result := 0;
        started := true;
      } else {
        let n = Char.toNat32(c);
        let digit : Nat = if (n >= 48 and n <= 57) { Nat32.toNat(n - 48) }
          else if (n >= 97 and n <= 102) { Nat32.toNat(n - 87) }
          else if (n >= 65 and n <= 70) { Nat32.toNat(n - 55) }
          else { 0 };
        result := result * 16 + digit;
      };
    };
    result;
  };

  /// Extract the next "0x..."-quoted hex value from text.
  func extractNextQuotedHex(text : Text) : Text {
    let chars = Iter.toArray(text.chars());
    let len = chars.size();
    var pos = 0;
    while (pos + 3 < len) {
      if (chars[pos] == '\"' and chars[Nat.add(pos, 1)] == '0' and chars[Nat.add(pos, 2)] == 'x') {
        let start = Nat.add(pos, 1);
        var end = start;
        while (end < len and chars[end] != '\"') { end += 1 };
        return textSlice(chars, start, end);
      };
      pos += 1;
    };
    "";
  };

  /// Get the text after the first occurrence of `needle` in `text`.
  func textAfter(text : Text, needle : Text) : Text {
    let chars = Iter.toArray(text.chars());
    let needleChars = Iter.toArray(needle.chars());
    let len = chars.size();
    let nLen = needleChars.size();
    if (nLen == 0) return text;

    var i = 0;
    while (i + nLen <= len) {
      var match = true;
      var j = 0;
      while (j < nLen) {
        if (chars[i + j] != needleChars[j]) { match := false; j := nLen } else { j += 1 };
      };
      if (match) {
        return textSlice(chars, i + nLen, len);
      };
      i += 1;
    };
    "";
  };

  // ── JSON field extraction ──

  func extractJsonField(json : Text, field : Text) : Text {
    let needle = "\"" # field # "\":\"";
    let chars = Iter.toArray(json.chars());
    let needleChars = Iter.toArray(needle.chars());
    let len = chars.size();
    let needleLen = needleChars.size();

    var i = 0;
    while (i + needleLen < len) {
      var match = true;
      var j = 0;
      while (j < needleLen) {
        if (chars[i + j] != needleChars[j]) {
          match := false;
          j := needleLen;
        } else {
          j += 1;
        };
      };
      if (match) {
        let start = i + needleLen;
        var end = start;
        while (end < len and not (chars[end] == QUOTE)) {
          end += 1;
        };
        return textSlice(chars, start, end);
      };
      i += 1;
    };
    "";
  };

  // ── Helpers ──

  func toLower(t : Text) : Text {
    Text.map(t, func(c : Char) : Char {
      if (c >= 'A' and c <= 'Z') {
        Char.fromNat32(Char.toNat32(c) + 32);
      } else { c };
    });
  };

  func textSlice(chars : [Char], start : Nat, end : Nat) : Text {
    var result = "";
    var k = start;
    while (k < end and k < chars.size()) {
      result := result # Char.toText(chars[k]);
      k += 1;
    };
    result;
  };
};
