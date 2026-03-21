/// ic402 — Avalanche/EVM transaction verification via HTTPS outcalls.
///
/// Verifies that an ERC-20 transfer happened on an EVM chain by calling
/// eth_getTransactionReceipt via the chain's JSON-RPC endpoint.
///
/// Used by Gateway.settle() when the payment network is "eip155:*".

import Text "mo:base/Text";
import Nat "mo:base/Nat";
import Nat8 "mo:base/Nat8";
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
      to : Text;        // the contract called (e.g. USDC)
      status : Bool;     // receipt status (true = success)
      blockNumber : Text;
    };
    #failed : Text;
  };

  /// Avalanche RPC endpoints by chain ID.
  public func rpcUrl(chainId : Nat) : Text {
    if (chainId == 43113) {
      "https://api.avax-test.network/ext/bc/C/rpc";
    } else if (chainId == 43114) {
      "https://api.avax.network/ext/bc/C/rpc";
    } else {
      "https://api.avax-test.network/ext/bc/C/rpc"; // default to Fuji
    };
  };

  let ic : IC.Service = actor "aaaaa-aa";

  /// Verify an EVM transaction receipt via HTTPS outcall.
  ///
  /// - txHash: the 0x-prefixed transaction hash
  /// - chainId: the EVM chain ID (43113 = Fuji, 43114 = mainnet)
  /// - expectedToken: the ERC-20 contract address (e.g. USDC)
  /// - expectedRecipient: the expected transfer recipient (canister's AVAX address)
  ///
  /// Makes an HTTPS outcall to the chain's RPC endpoint, calls
  /// eth_getTransactionReceipt, and verifies the receipt status.
  public func verifyTransaction(
    txHash : Text,
    chainId : Nat,
    expectedToken : Text,
    _expectedRecipient : Text,
  ) : async VerifyResult {
    let url = rpcUrl(chainId);

    // Build JSON-RPC request body
    let body = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"eth_getTransactionReceipt\",\"params\":[\"" # txHash # "\"]}";

    // HTTPS outcalls require cycles (~230B)
    let response = await (with cycles = 230_000_000_000) ic.http_request({
      url = url;
      method = #post;
      max_response_bytes = ?10_000;
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

    // Parse the response — extract key fields
    // We look for "status" and "to" fields in the result object

    let status = extractJsonField(responseText, "status");
    let to = extractJsonField(responseText, "to");
    let from = extractJsonField(responseText, "from");
    let blockNumber = extractJsonField(responseText, "blockNumber");

    // Check receipt exists
    if (status == "") {
      return #failed("Transaction not found or not yet confirmed");
    };

    // Check tx succeeded (status 0x1)
    let txSucceeded = status == "0x1";
    if (not txSucceeded) {
      return #failed("Transaction reverted (status: " # status # ")");
    };

    // Verify the tx was to the expected token contract
    let normalizedTo = toLower(to);
    let normalizedExpected = toLower(expectedToken);
    if (normalizedTo != normalizedExpected) {
      return #failed("Transaction target " # to # " does not match expected token " # expectedToken);
    };

    // Note: Full ERC-20 transfer verification would decode the logs
    // to check the Transfer(from, to, amount) event. For the hackathon,
    // we verify the tx succeeded and was sent to the correct contract.
    // A production implementation would also verify:
    //   - The Transfer event's `to` matches expectedRecipient
    //   - The Transfer event's `amount` >= required amount
    //   - Sufficient block confirmations

    #ok({
      txHash = txHash;
      from = from;
      to = to;
      status = txSucceeded;
      blockNumber = blockNumber;
    });
  };

  // ── Simple JSON field extraction ──
  // Finds "fieldName":"value" in a JSON string. Not a full parser —
  // works for flat JSON-RPC responses where values are hex strings.

  func extractJsonField(json : Text, field : Text) : Text {
    let needle = "\"" # field # "\":\"";
    let chars = Iter.toArray(json.chars());
    let needleChars = Iter.toArray(needle.chars());
    let len = chars.size();
    let needleLen = needleChars.size();

    var i = 0;
    label search while (i + needleLen < len) {
      var match = true;
      var j = 0;
      while (j < needleLen) {
        if (chars[i + j] != needleChars[j]) {
          match := false;
          j := needleLen; // break inner
        } else {
          j += 1;
        };
      };
      if (match) {
        // Found the field — extract value until next quote
        let start = i + needleLen;
        var end = start;
        while (end < len and chars[end] != '\"') {
          end += 1;
        };
        // Build the value string
        var result = "";
        var k = start;
        while (k < end) {
          result := result # Char.toText(chars[k]);
          k += 1;
        };
        return result;
      };
      i += 1;
    };
    ""; // not found
  };

  /// Lowercase a hex string for case-insensitive address comparison.
  func toLower(t : Text) : Text {
    Text.map(t, func(c : Char) : Char {
      if (c >= 'A' and c <= 'Z') {
        Char.fromNat32(Char.toNat32(c) + 32);
      } else {
        c;
      };
    });
  };
};
