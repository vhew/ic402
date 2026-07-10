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
import EvmUtils "EvmUtils";
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

  /// Render the x402 v2 `accepts` array (the list of PaymentRequirements). Reused by the 402
  /// challenge and by the discovery listing. PaymentRequirements use the v2 field names
  /// (`amount`, not `maxAmountRequired`), CAIP-2 `network`, and a real `maxTimeoutSeconds`. The
  /// non-standard ic402 server nonce/expiry live under `extra` where a stock client ignores them.
  /// EIP-712 domain-name fallback for a token configured without `tokenName`. The name is
  /// load-bearing: it enters the domain separator the payer signs and the token contract
  /// verifies on-chain — a wrong name makes every transferWithAuthorization revert with an
  /// invalid signature. Configure `tokenName` explicitly; this table covers only the
  /// canonical USDC deployments the docs and demo use. NB: Base Sepolia USDC (FiatToken
  /// v2.2) is "USDC", NOT "USD Coin" (which is correct for Base mainnet).
  func defaultEip712Name(network : Text, token : Text) : Text {
    if (network == "eip155:84532" and Utils.toLower(token) == "0x036cbd53842c5426634e7929541ec2318f3dcf7e") {
      "USDC";
    } else {
      "USD Coin";
    };
  };

  public func acceptsArrayJson(requirements : [Types.PaymentRequirement]) : Text {
    let now = Time.now();
    var accepts = "";
    // requirements.keys() avoids the `size() - 1` Nat underflow trap on an empty array.
    for (i in requirements.keys()) {
      let r = requirements[i];
      if (i > 0) { accepts #= "," };
      let tName = switch (r.tokenName) { case (?n) { n }; case (null) { defaultEip712Name(r.network, r.token) } };
      let tVersion = switch (r.tokenVersion) { case (?v) { v }; case (null) { "2" } };
      // v2 maxTimeoutSeconds = the real remaining challenge window — but strictly POSITIVE:
      // the official v2 schema requires > 0, and a 0 makes strict clients reject the whole
      // PaymentRequired. expiry == 0 marks a listing with no live nonce (Gateway.describe /
      // the discovery endpoint) — advertise the standard challenge window instead; an
      // expired or sub-second window floors at 1.
      let timeout : Int = if (r.expiry == 0) { 300 } else if (r.expiry > now) {
        let t = (r.expiry - now) / 1_000_000_000;
        if (t < 1) { 1 } else { t };
      } else { 1 };
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
    "[" # accepts # "]";
  };

  /// Build the x402 v2 `PaymentRequired` JSON object.
  /// Shape: { x402Version:2, error?, resource:ResourceInfo, accepts:[PaymentRequirements...] }.
  public func paymentRequiredJson(requirements : [Types.PaymentRequirement], resourceUrl : Text, errorMsg : ?Text) : Text {
    let errPart = switch (errorMsg) {
      case (?m) { "\"error\":\"" # Utils.escapeJsonString(m) # "\"," };
      case (null) { "" };
    };
    "{\"x402Version\":2," # errPart
      # "\"resource\":{\"url\":\"" # Utils.escapeJsonString(resourceUrl) # "\"}"
      # ",\"accepts\":" # acceptsArrayJson(requirements) # "}";
  };

  /// One entry in the x402 discovery (`GET /discovery/resources`) listing. `acceptsJson` is the
  /// pre-rendered v2 accepts array (e.g. from acceptsArrayJson). The resource URL is escaped here.
  public func discoveryItemJson(resourceUrl : Text, resType : Text, acceptsJson : Text) : Text {
    "{\"resource\":\"" # Utils.escapeJsonString(resourceUrl) # "\""
      # ",\"type\":\"" # Utils.escapeJsonString(resType) # "\""
      # ",\"x402Version\":2,\"accepts\":" # acceptsJson # "}";
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

  /// 402 carrying a v2 `SettlementResponse` (a settlement FAILURE on a paid request) — both in
  /// the `PAYMENT-RESPONSE` header and the body, instead of an ad-hoc `{"error":...}`.
  public func http402WithSettlement(settlementJson : Text) : Types.HttpResponse {
    let b64 = Utils.base64Encode(Blob.toArray(Text.encodeUtf8(settlementJson)));
    {
      status_code = 402;
      headers = Array.append(corsHeaders(), [("Content-Type", "application/json"), ("PAYMENT-RESPONSE", b64)]);
      body = Text.encodeUtf8(settlementJson);
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

  /// x402 v2 facilitator `POST /verify` response: { isValid, invalidReason?, payer? }.
  public func verifyResponseJson(isValid : Bool, invalidReason : ?Text, payer : ?Text) : Text {
    let reasonPart = switch (invalidReason) {
      case (?r) { ",\"invalidReason\":\"" # Utils.escapeJsonString(r) # "\"" };
      case (null) { "" };
    };
    let payerPart = switch (payer) {
      case (?p) { ",\"payer\":\"" # Utils.escapeJsonString(p) # "\"" };
      case (null) { "" };
    };
    "{\"isValid\":" # (if (isValid) { "true" } else { "false" }) # reasonPart # payerPart # "}";
  };

  /// Parse a facilitator `POST /verify`|`/settle` body: { x402Version, paymentPayload, paymentRequirements }.
  /// Returns the exact-EVM authorization as a PaymentSignature (with an EMPTY server nonce — the
  /// facilitator path binds the amount via the supplied requirement, not a server nonce) plus the
  /// authoritative amount/payTo/asset taken from `paymentRequirements` (NOT the client's echoed
  /// `accepted`, which a malicious client could understate).
  public func parseFacilitatorRequest(json : Text) : ?{ sig : Types.PaymentSignature; amount : Nat; payTo : Text; asset : Text } {
    // Isolate the paymentRequirements sub-object so amount/payTo/asset come from the server's
    // requirement, not from an `accepted`/`amount` that appears earlier inside paymentPayload.
    let reqParts = Iter.toArray(Text.split(json, #text "\"paymentRequirements\""));
    let reqPart = if (reqParts.size() >= 2) { reqParts[1] } else { json };

    let network = Utils.extractJsonField(reqPart, "network");
    let payTo = Utils.extractJsonField(reqPart, "payTo");
    let asset = Utils.extractJsonField(reqPart, "asset");
    let amount = Utils.extractJsonNatField(reqPart, "amount");
    if (network == "" or payTo == "" or amount == 0) return null;

    // Authorization fields are unique within the body (requirements have no from/to/value).
    let from = Utils.extractJsonField(json, "from");
    let to = Utils.extractJsonField(json, "to");
    let value = Utils.extractJsonNatField(json, "value");
    let validAfter = Utils.extractJsonNatField(json, "validAfter");
    let validBefore = Utils.extractJsonNatField(json, "validBefore");
    let authzNonce = Utils.extractJsonField(json, "nonce");
    let sigHex = Utils.extractJsonField(json, "signature");
    if (from == "" or to == "" or sigHex == "" or authzNonce == "") return null;

    let sigBytes = hexToBytes(sigHex);
    if (sigBytes.size() != 65) return null;
    let r = Blob.fromArray(arraySlice(sigBytes, 0, 32));
    let s = Blob.fromArray(arraySlice(sigBytes, 32, 32));
    let v = sigBytes[64];

    ?{
      sig = {
        scheme = "exact";
        network;
        signature = Blob.fromArray([]);
        publicKey = null;
        asset = if (asset != "") { ?asset } else { null };
        sender = from;
        nonce = Blob.fromArray([]); // facilitator: no server nonce
        authorization = ?{
          from;
          to;
          value;
          validAfter;
          validBefore;
          nonce = Blob.fromArray(hexToBytes(authzNonce));
          v = EvmUtils.recoveryIdFromV(v); // 27/28 → 0/1 for ic402's internal ecRecover
          r;
          s;
        };
      };
      amount;
      payTo;
      asset;
    };
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

  /// 202 Accepted (JSON) carrying the v2 `PAYMENT-RESPONSE` settlement header — for async flows
  /// where the payment settled but the work product is still pending (e.g. a marketplace job was
  /// created and escrowed; the body points the client at a poll URL).
  public func http202JsonWithSettlement(json : Text, settlementJson : Text) : Types.HttpResponse {
    let b64 = Utils.base64Encode(Blob.toArray(Text.encodeUtf8(settlementJson)));
    {
      status_code = 202;
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

  /// Extract a raw query parameter value from a URL. The value is returned WITHOUT
  /// percent-decoding, and a value containing '=' is truncated at the second '=' (only the
  /// segment between the first two '=' delimiters is returned) — do not route base64 or
  /// percent-encoded payloads through this helper without decoding/handling on your side.
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
  /// Legacy ICP-rail parser: the result always has `asset = null` and `authorization = null`.
  /// Do NOT use it for EVM payments — settle would fall back to the chain's first configured
  /// token (Types.PaymentSignature.asset); use parseX402PaymentHeader for the standard x402
  /// EVM header. Returns null on any missing field; malformed hex degrades to an empty blob
  /// (failed verification) rather than trapping.
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
      asset = null; // legacy ICP header carries no EVM asset
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
    // The token contract the payer signed for (EIP-712 verifyingContract), from the echoed
    // `accepted` PaymentRequirements. Lets settle key the domain + execution token off THIS asset
    // on a multi-token chain instead of the first configured token. Empty (legacy) → null.
    let assetAddr = Utils.extractJsonField(json, "asset");

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
      asset = if (assetAddr != "") { ?assetAddr } else { null };
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
        v = EvmUtils.recoveryIdFromV(v); // 27/28 → 0/1 for ic402's internal ecRecover
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
    let hexLen = Utils.satSub(chars.size(), start);
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
    // L22: use the LOCAL non-trapping hexToBytes ([] on odd-length / non-hex input). The
    // Ed25519.Utils version traps (Option.unwrap on a bad nibble, and a Nat underflow on a 1-char
    // value), and parsePaymentHeader reaches this on a fully attacker-controlled PAYMENT-SIGNATURE
    // header — a malformed value must degrade to a failed verification, not trap http_request_update.
    Blob.fromArray(hexToBytes(hex));
  };

};
