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
import Int "mo:base/Int";
import Iter "mo:base/Iter";
import Ed25519 "mo:ed25519";
import Utils "Utils";

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

  func blobToHex(b : Blob) : Text {
    Ed25519.Utils.bytesToHex(Blob.toArray(b));
  };

  func hexToBlob(hex : Text) : Blob {
    Blob.fromArray(Ed25519.Utils.hexToBytes(hex));
  };

};
