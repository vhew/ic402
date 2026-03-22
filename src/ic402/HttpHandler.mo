/// ic402 — HTTP handler for x402 payment-gated content serving.
///
/// Serves content via ICP's HTTP gateway with standard x402 402 responses.
/// Integrates with Gateway (payment) and ContentStore (storage).
///
/// Routes:
///   GET /                          → agent info (free)
///   GET /content/<id>              → paid content (402 → pay → 200)
///   GET /search?q=<query>          → paid search (402 → pay → 200)
///
/// x402 flow over HTTP:
///   1. Client GETs a paid resource
///   2. Canister returns 402 with PaymentRequirement JSON
///   3. Client pays (ICRC-2 or Avalanche USDC)
///   4. Client retries with X-PAYMENT header containing the signature
///   5. Canister settles payment and returns content

import Types "Types";
import Text "mo:base/Text";
import Blob "mo:base/Blob";
import Nat "mo:base/Nat";
import Nat8 "mo:base/Nat8";
import Int "mo:base/Int";
import Iter "mo:base/Iter";
import Array "mo:base/Array";
import Char "mo:base/Char";
import Nat32 "mo:base/Nat32";

module {

  /// Build a JSON string from PaymentRequirements for the 402 response body.
  /// Follows x402 convention: { "x402Version": 1, "accepts": [...] }
  public func paymentRequiredJson(requirements : [Types.PaymentRequirement]) : Text {
    var accepts = "";
    for (i in Iter.range(0, requirements.size() - 1)) {
      let r = requirements[i];
      if (i > 0) { accepts #= "," };
      accepts #= "{\"scheme\":\"" # r.scheme # "\""
        # ",\"network\":\"" # r.network # "\""
        # ",\"token\":\"" # r.token # "\""
        # ",\"maxAmountRequired\":\"" # Nat.toText(r.amount) # "\""
        # ",\"payTo\":\"" # r.recipient # "\""
        # ",\"nonce\":\"" # blobToHex(r.nonce) # "\""
        # ",\"maxTimeoutSeconds\":" # Int.toText(300)
        # "}";
    };
    "{\"x402Version\":1,\"accepts\":[" # accepts # "]}";
  };

  /// Build a 402 Payment Required HTTP response.
  public func http402(requirements : [Types.PaymentRequirement]) : Types.HttpResponse {
    let body = paymentRequiredJson(requirements);
    {
      status_code = 402;
      headers = [
        ("Content-Type", "application/json"),
        ("Access-Control-Allow-Origin", "*"),
        ("X-Payment-Required", "true"),
      ];
      body = Text.encodeUtf8(body);
      upgrade = null;
    };
  };

  /// Build a 200 OK response with content.
  public func http200(contentBody : Blob, mimeType : Text) : Types.HttpResponse {
    {
      status_code = 200;
      headers = [
        ("Content-Type", mimeType),
        ("Access-Control-Allow-Origin", "*"),
      ];
      body = contentBody;
      upgrade = null;
    };
  };

  /// Build a 200 OK JSON response.
  public func http200Json(json : Text) : Types.HttpResponse {
    {
      status_code = 200;
      headers = [
        ("Content-Type", "application/json"),
        ("Access-Control-Allow-Origin", "*"),
      ];
      body = Text.encodeUtf8(json);
      upgrade = null;
    };
  };

  /// Build an error response.
  public func httpError(status : Nat16, message : Text) : Types.HttpResponse {
    {
      status_code = status;
      headers = [
        ("Content-Type", "application/json"),
        ("Access-Control-Allow-Origin", "*"),
      ];
      body = Text.encodeUtf8("{\"error\":\"" # message # "\"}");
      upgrade = null;
    };
  };

  /// Build an upgrade response (tells HTTP gateway to retry as update call).
  public func httpUpgrade() : Types.HttpResponse {
    {
      status_code = 200;
      headers = [];
      body = Blob.fromArray([]);
      upgrade = ?true;
    };
  };

  // ── URL parsing ──

  /// Extract the path from a URL (before '?').
  public func getPath(url : Text) : Text {
    switch (Text.split(url, #char '?').next()) {
      case (?p) { p };
      case (null) { url };
    };
  };

  /// Extract a query parameter value from a URL.
  public func getQueryParam(url : Text, param : Text) : ?Text {
    let parts = Iter.toArray(Text.split(url, #char '?'));
    if (parts.size() < 2) return null;

    let pairs = Text.split(parts[1], #char '&');
    for (pair in pairs) {
      let kv = Iter.toArray(Text.split(pair, #char '='));
      if (kv.size() >= 2 and kv[0] == param) {
        return ?kv[1];
      };
    };
    null;
  };

  /// Get a header value (case-insensitive).
  public func getHeader(headers : [(Text, Text)], name : Text) : ?Text {
    let lower = toLower(name);
    for ((k, v) in headers.vals()) {
      if (toLower(k) == lower) return ?v;
    };
    null;
  };

  /// Parse X-PAYMENT header JSON into a PaymentSignature.
  /// Expects: {"scheme":"exact","network":"...","signature":"...","sender":"...","nonce":"..."}
  public func parsePaymentHeader(json : Text) : ?Types.PaymentSignature {
    let scheme = extractField(json, "scheme");
    let network = extractField(json, "network");
    let signature = extractField(json, "signature");
    let sender = extractField(json, "sender");
    let nonce = extractField(json, "nonce");

    if (scheme == "" or network == "" or sender == "" or nonce == "") {
      return null;
    };

    ?{
      scheme;
      network;
      signature = hexToBlob(signature);
      sender;
      nonce = hexToBlob(nonce);
    };
  };

  // ── Internal helpers ──

  func toLower(t : Text) : Text {
    Text.map(t, func(c : Char) : Char {
      if (c >= 'A' and c <= 'Z') {
        Char.fromNat32(Char.toNat32(c) + 32);
      } else {
        c;
      };
    });
  };

  func blobToHex(b : Blob) : Text {
    let bytes = Blob.toArray(b);
    var hex = "";
    for (byte in bytes.vals()) {
      hex #= hexChar(byte / 16) # hexChar(byte % 16);
    };
    hex;
  };

  func hexChar(n : Nat8) : Text {
    let chars = ["0","1","2","3","4","5","6","7","8","9","a","b","c","d","e","f"];
    chars[Nat8.toNat(n)];
  };

  func hexToBlob(hex : Text) : Blob {
    let chars = Iter.toArray(hex.chars());
    let len = chars.size() / 2;
    let bytes = Array.tabulate<Nat8>(len, func(i : Nat) : Nat8 {
      let hi = hexVal(chars[i * 2]);
      let lo = hexVal(chars[i * 2 + 1]);
      hi * 16 + lo;
    });
    Blob.fromArray(bytes);
  };

  func hexVal(c : Char) : Nat8 {
    let n = Char.toNat32(c);
    if (n >= 48 and n <= 57) { Nat8.fromNat(Nat.sub(Char.toNat32(c) |> Nat32.toNat(_), 48)) }
    else if (n >= 97 and n <= 102) { Nat8.fromNat(Nat.sub(Char.toNat32(c) |> Nat32.toNat(_), 87)) }
    else if (n >= 65 and n <= 70) { Nat8.fromNat(Nat.sub(Char.toNat32(c) |> Nat32.toNat(_), 55)) }
    else { 0 };
  };

  func extractField(json : Text, field : Text) : Text {
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
        while (end < len and chars[end] != '\"') {
          end += 1;
        };
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
    "";
  };
};
