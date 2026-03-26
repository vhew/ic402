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
///   3. Client pays (ICRC-2 or EVM USDC)
///   4. Client retries with X-PAYMENT header containing the signature
///   5. Canister settles payment and returns content

import Types "Types";
import Text "mo:base/Text";
import Blob "mo:base/Blob";
import Nat "mo:base/Nat";
import Nat8 "mo:base/Nat8";
import Nat32 "mo:base/Nat32";
import Int "mo:base/Int";
import Array "mo:base/Array";
import Buffer "mo:base/Buffer";
import Char "mo:base/Char";
import Iter "mo:base/Iter";
import Ed25519 "mo:ed25519";
import Utils "Utils";

module {

  /// Build a JSON string from PaymentRequirements for the 402 response body.
  /// Follows x402 v1 convention: { "x402Version": 1, "accepts": [...] }
  /// Includes both x402-standard fields (asset, payTo, maxAmountRequired) and
  /// ic402 fields (token, recipient, amount, nonce) for compatibility.
  public func paymentRequiredJson(requirements : [Types.PaymentRequirement]) : Text {
    var accepts = "";
    for (i in Iter.range(0, requirements.size() - 1)) {
      let r = requirements[i];
      if (i > 0) { accepts #= "," };
      let tName = switch (r.tokenName) { case (?n) { n }; case (null) { "USD Coin" } };
      let tVersion = switch (r.tokenVersion) { case (?v) { v }; case (null) { "2" } };
      accepts #= "{\"scheme\":\"" # Utils.escapeJsonString(r.scheme) # "\""
        # ",\"network\":\"" # Utils.escapeJsonString(r.network) # "\""
        # ",\"asset\":\"" # Utils.escapeJsonString(r.token) # "\""
        # ",\"maxAmountRequired\":\"" # Nat.toText(r.amount) # "\""
        # ",\"payTo\":\"" # Utils.escapeJsonString(r.recipient) # "\""
        # ",\"maxTimeoutSeconds\":" # Int.toText(300)
        # ",\"extra\":{\"name\":\"" # Utils.escapeJsonString(tName) # "\",\"version\":\"" # Utils.escapeJsonString(tVersion) # "\"}"
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
        ("WWW-Authenticate", "Payment realm=\"ic402\", method=\"x402\""),
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
      body = Text.encodeUtf8("{\"error\":\"" # Utils.escapeJsonString(message) # "\"}");
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
    let lower = Utils.toLower(name);
    for ((k, v) in headers.vals()) {
      if (Utils.toLower(k) == lower) return ?v;
    };
    null;
  };

  /// Parse X-PAYMENT header JSON into a PaymentSignature.
  /// Expects: {"scheme":"exact","network":"...","signature":"...","sender":"...","nonce":"..."}
  public func parsePaymentHeader(json : Text) : ?Types.PaymentSignature {
    let scheme = Utils.extractJsonField(json, "scheme");
    let network = Utils.extractJsonField(json, "network");
    let signature = Utils.extractJsonField(json, "signature");
    let sender = Utils.extractJsonField(json, "sender");
    let nonce = Utils.extractJsonField(json, "nonce");

    if (scheme == "" or network == "" or signature == "" or sender == "" or nonce == "") {
      return null;
    };

    ?{
      scheme;
      network;
      signature = hexToBlob(signature);
      publicKey = null;
      sender;
      nonce = hexToBlob(nonce);
      authorization = null;
    };
  };

  /// Parse a standard x402 X-PAYMENT header (base64-encoded JSON with EIP-3009 authorization).
  /// Returns a PaymentSignature with the authorization field populated.
  ///
  /// Expected base64-decoded JSON:
  /// {"x402Version":1,"scheme":"exact","network":"eip155:84532",
  ///  "payload":{"signature":"0x...","authorization":{"from":"0x...","to":"0x...","value":"1000",
  ///  "validAfter":"0","validBefore":"...","nonce":"0x..."}}}
  public func parseX402PaymentHeader(base64Header : Text) : ?Types.PaymentSignature {
    let decoded = Utils.base64Decode(base64Header);
    if (decoded.size() == 0) return null;
    let json = switch (Text.decodeUtf8(Blob.fromArray(decoded))) {
      case (?t) { t };
      case (null) { return null };
    };

    let scheme = Utils.extractJsonField(json, "scheme");
    let network = Utils.extractJsonField(json, "network");
    if (scheme == "" or network == "") return null;

    // Extract payload.authorization fields
    let from = Utils.extractJsonField(json, "from");
    let to = Utils.extractJsonField(json, "to");
    let value = Utils.extractJsonNatField(json, "value");
    let validAfter = Utils.extractJsonNatField(json, "validAfter");
    let validBefore = Utils.extractJsonNatField(json, "validBefore");
    let nonce = Utils.extractJsonField(json, "nonce");
    let sig = Utils.extractJsonField(json, "signature");

    if (from == "" or to == "" or sig == "" or nonce == "") return null;

    // Parse the 65-byte EIP-712 signature (r + s + v)
    let sigBytes = hexToBytes(sig);
    if (sigBytes.size() != 65) return null;

    let r = Blob.fromArray(arraySlice(sigBytes, 0, 32));
    let s = Blob.fromArray(arraySlice(sigBytes, 32, 32));
    let v = sigBytes[64];

    ?{
      scheme;
      network;
      signature = Blob.fromArray([]);
      publicKey = null;
      sender = from;
      nonce = Blob.fromArray([]);
      authorization = ?{
        from;
        to;
        value;
        validAfter;
        validBefore;
        nonce = Blob.fromArray(hexToBytes(nonce));
        v = if (v >= 27) { v - 27 : Nat8 } else { v }; // Normalize v (27/28 → 0/1)
        r;
        s;
      };
    };
  };

  func arraySlice(arr : [Nat8], start : Nat, len : Nat) : [Nat8] {
    Array.tabulate<Nat8>(len, func(i) { arr[start + i] });
  };

  func hexToBytes(hex : Text) : [Nat8] {
    let chars = Iter.toArray(hex.chars());
    var start : Nat = 0;
    if (chars.size() >= 2 and chars[0] == '0' and (chars[1] == 'x' or chars[1] == 'X')) {
      start := 2;
    };
    let hexLen = chars.size() - start;
    if (hexLen % 2 != 0) return [];
    let buf = Buffer.Buffer<Nat8>(hexLen / 2);
    var i = start;
    while (i + 1 < chars.size()) {
      let hi = hexCharVal(chars[i]);
      let lo = hexCharVal(chars[i + 1]);
      if (hi == 255 or lo == 255) return [];
      buf.add(Nat8.fromNat(Nat8.toNat(hi) * 16 + Nat8.toNat(lo)));
      i += 2;
    };
    Buffer.toArray(buf);
  };

  func hexCharVal(c : Char) : Nat8 {
    let n = Char.toNat32(c);
    if (n >= 48 and n <= 57) { Nat8.fromNat(Nat32.toNat(n - 48)) }
    else if (n >= 97 and n <= 102) { Nat8.fromNat(Nat32.toNat(n - 87)) }
    else if (n >= 65 and n <= 70) { Nat8.fromNat(Nat32.toNat(n - 55)) }
    else { 255 : Nat8 };
  };

  // ── Internal helpers ──

  func blobToHex(b : Blob) : Text {
    Ed25519.Utils.bytesToHex(Blob.toArray(b));
  };

  func hexToBlob(hex : Text) : Blob {
    Blob.fromArray(Ed25519.Utils.hexToBytes(hex));
  };

};
