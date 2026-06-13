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
import Time "mo:base/Time";
import Array "mo:base/Array";
import Buffer "mo:base/Buffer";
import Char "mo:base/Char";
import Iter "mo:base/Iter";
import Ed25519 "mo:ed25519";
import Utils "Utils";

module {

  /// Standard CORS + x402 header-transport headers attached to every response, so a
  /// browser agent can (a) pass the OPTIONS preflight carrying the custom
  /// `PAYMENT-SIGNATURE` request header and (b) actually READ the `PAYMENT-REQUIRED` /
  /// `PAYMENT-RESPONSE` response headers (without `Access-Control-Expose-Headers`,
  /// `Allow-Origin: *` hides all non-safelisted response headers from JS).
  public func corsHeaders() : [(Text, Text)] {
    [
      ("Access-Control-Allow-Origin", "*"),
      ("Access-Control-Allow-Methods", "GET, POST, OPTIONS"),
      ("Access-Control-Allow-Headers", "PAYMENT-SIGNATURE, X-Payment, Content-Type"),
      ("Access-Control-Expose-Headers", "PAYMENT-REQUIRED, PAYMENT-RESPONSE"),
    ];
  };

  /// Build the absolute resource URL for x402 v2 `ResourceInfo.url`. ICP's `request.url`
  /// is only the path+query (no scheme/host), so the origin is taken from the `Host` header.
  public func buildResourceUrl(headers : [(Text, Text)], url : Text) : Text {
    let path = getPath(url);
    switch (getHeader(headers, "host")) {
      case (?host) { if (host == "") { path } else { "https://" # host # path } };
      case (null) { path };
    };
  };

  /// Build the x402 v2 `PaymentRequired` JSON object.
  /// Shape: { x402Version:2, error?, resource:ResourceInfo, accepts:[PaymentRequirements...] }.
  /// PaymentRequirements use the v2 field names (`amount`, not `maxAmountRequired`), CAIP-2
  /// `network`, and a real `maxTimeoutSeconds`. The non-standard ic402 server nonce/expiry live
  /// under `extra` (the only spec-sanctioned bag) where a stock client ignores them.
  public func paymentRequiredJson(requirements : [Types.PaymentRequirement], resourceUrl : Text, errorMsg : ?Text) : Text {
    let now = Time.now();
    var accepts = "";
    for (i in Iter.range(0, requirements.size() - 1)) {
      let r = requirements[i];
      if (i > 0) { accepts #= "," };
      let tName = switch (r.tokenName) { case (?n) { n }; case (null) { "USD Coin" } };
      let tVersion = switch (r.tokenVersion) { case (?v) { v }; case (null) { "2" } };
      // v2 maxTimeoutSeconds = the real remaining challenge window, not a constant.
      let timeout : Int = if (r.expiry > now) { (r.expiry - now) / 1_000_000_000 } else { 0 };
      accepts #= "{\"scheme\":\"" # Utils.escapeJsonString(r.scheme) # "\""
        # ",\"network\":\"" # Utils.escapeJsonString(r.network) # "\""
        # ",\"amount\":\"" # Nat.toText(r.amount) # "\""
        # ",\"asset\":\"" # Utils.escapeJsonString(r.token) # "\""
        # ",\"payTo\":\"" # Utils.escapeJsonString(r.recipient) # "\""
        # ",\"maxTimeoutSeconds\":" # Int.toText(timeout)
        // extra = EIP-712 domain (name/version, load-bearing for signature verification),
        // the default asset-transfer method, and the NON-STANDARD ic402 server nonce/expiry
        // (unique key names so the flat JSON reader never collides with authorization.nonce;
        // stock x402 clients ignore them — only the ic402 server-nonce binding on the
        // ICP/legacy rail reads them back).
        # ",\"extra\":{\"name\":\"" # Utils.escapeJsonString(tName) # "\""
        # ",\"version\":\"" # Utils.escapeJsonString(tVersion) # "\""
        # ",\"assetTransferMethod\":\"eip3009\""
        # ",\"ic402Nonce\":\"" # blobToHex(r.nonce) # "\""
        # ",\"ic402Expiry\":" # Int.toText(r.expiry) # "}"
        # "}";
    };
    let errPart = switch (errorMsg) {
      case (?m) { "\"error\":\"" # Utils.escapeJsonString(m) # "\"," };
      case (null) { "" };
    };
    "{\"x402Version\":2," # errPart
      # "\"resource\":{\"url\":\"" # Utils.escapeJsonString(resourceUrl) # "\"}"
      # ",\"accepts\":[" # accepts # "]}";
  };

  /// Build a 402 Payment Required response (x402 v2). The `PaymentRequired` object travels in
  /// the base64 `PAYMENT-REQUIRED` header (v2 header transport); the JSON body carries the same
  /// object for non-browser tooling.
  public func http402(requirements : [Types.PaymentRequirement], resourceUrl : Text) : Types.HttpResponse {
    let body = paymentRequiredJson(requirements, resourceUrl, ?"PAYMENT-SIGNATURE header is required");
    let base64Header = Utils.base64Encode(Blob.toArray(Text.encodeUtf8(body)));
    {
      status_code = 402;
      headers = Array.append(corsHeaders(), [
        ("Content-Type", "application/json"),
        ("PAYMENT-REQUIRED", base64Header),
      ]);
      body = Text.encodeUtf8(body);
      upgrade = null;
    };
  };

  /// CORS preflight response for the v2 custom request header `PAYMENT-SIGNATURE`.
  public func httpOptions() : Types.HttpResponse {
    { status_code = 204; headers = corsHeaders(); body = Blob.fromArray([]); upgrade = null };
  };

  /// Build the x402 v2 `SettlementResponse` JSON, emitted in the `PAYMENT-RESPONSE` header.
  public func settlementResponseJson(success : Bool, txHash : ?Text, network : Text, payer : Text, amount : Nat, errorReason : ?Text) : Text {
    let tx = switch (txHash) { case (?h) { h }; case (null) { "" } };
    let errPart = switch (errorReason) {
      case (?e) { ",\"errorReason\":\"" # Utils.escapeJsonString(e) # "\"" };
      case (null) { "" };
    };
    "{\"success\":" # (if (success) { "true" } else { "false" })
      # ",\"transaction\":\"" # Utils.escapeJsonString(tx) # "\""
      # ",\"network\":\"" # Utils.escapeJsonString(network) # "\""
      # ",\"payer\":\"" # Utils.escapeJsonString(payer) # "\""
      # ",\"amount\":\"" # Nat.toText(amount) # "\""
      # errPart # "}";
  };

  /// 200 (binary content) carrying the v2 `PAYMENT-RESPONSE` settlement header.
  public func http200WithSettlement(contentBody : Blob, mimeType : Text, settlementJson : Text) : Types.HttpResponse {
    let b64 = Utils.base64Encode(Blob.toArray(Text.encodeUtf8(settlementJson)));
    {
      status_code = 200;
      headers = Array.append(corsHeaders(), [("Content-Type", mimeType), ("PAYMENT-RESPONSE", b64)]);
      body = contentBody;
      upgrade = null;
    };
  };

  /// 200 (JSON) carrying the v2 `PAYMENT-RESPONSE` settlement header.
  public func http200JsonWithSettlement(json : Text, settlementJson : Text) : Types.HttpResponse {
    let b64 = Utils.base64Encode(Blob.toArray(Text.encodeUtf8(settlementJson)));
    {
      status_code = 200;
      headers = Array.append(corsHeaders(), [("Content-Type", "application/json"), ("PAYMENT-RESPONSE", b64)]);
      body = Text.encodeUtf8(json);
      upgrade = null;
    };
  };

  /// Build a 200 OK response with content.
  public func http200(contentBody : Blob, mimeType : Text) : Types.HttpResponse {
    {
      status_code = 200;
      headers = Array.append(corsHeaders(), [("Content-Type", mimeType)]);
      body = contentBody;
      upgrade = null;
    };
  };

  /// Build a 200 OK JSON response.
  public func http200Json(json : Text) : Types.HttpResponse {
    {
      status_code = 200;
      headers = Array.append(corsHeaders(), [("Content-Type", "application/json")]);
      body = Text.encodeUtf8(json);
      upgrade = null;
    };
  };

  /// Build an error response.
  public func httpError(status : Nat16, message : Text) : Types.HttpResponse {
    {
      status_code = status;
      headers = Array.append(corsHeaders(), [("Content-Type", "application/json")]);
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

  /// Build a 202 Accepted JSON response (for async service requests).
  public func http202Json(json : Text) : Types.HttpResponse {
    {
      status_code = 202;
      headers = Array.append(corsHeaders(), [("Content-Type", "application/json")]);
      body = Text.encodeUtf8(json);
      upgrade = null;
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
    // H-10 (v2): the echoed ic402 server nonce (hex), if the client included it.
    let ic402Nonce = Utils.extractJsonField(json, "ic402Nonce");

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
      // H-10: carry the echoed server nonce so Gateway.settle can lock the bound
      // amount. Empty when the client did not echo it (then settle returns
      // #expired rather than silently settling an unbound amount).
      nonce = if (ic402Nonce != "") { Blob.fromArray(hexToBytes(ic402Nonce)) } else { Blob.fromArray([]) };
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
