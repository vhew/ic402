/// ic402 — x402 client: canister pays for external x402-gated content.
///
/// Signs EIP-3009 TransferWithAuthorization via tECDSA and sends
/// the authorization in the standard X-PAYMENT header.
///
/// Adaptive response sizing minimizes cycle cost:
///   1. Initial 402 probe: 8KB (payment metadata is ~1-2KB)
///   2. Paid retry: content-length hint → 256KB default → 2MB fallback
///
/// Error classification:
///   #ok / #free          — success
///   #paymentFailed       — permanent: bad signature, wrong chain, server rejection
///   #httpError           — non-402 HTTP error from the server
///   #transientError      — retryable: network timeout, adapter saturated

import Blob "mo:base/Blob";
import Array "mo:base/Array";
import Int "mo:base/Int";
import Nat "mo:base/Nat";
import Nat8 "mo:base/Nat8";
import Nat32 "mo:base/Nat32";
import Nat64 "mo:base/Nat64";
import Char "mo:base/Char";
import Text "mo:base/Text";
import Time "mo:base/Time";
import Error "mo:base/Error";
import EvmAddress "EvmAddress";
import EvmUtils "EvmUtils";
import Eip712 "Eip712";
import Utils "Utils";
import IC "mo:ic";
import Call "mo:ic/Call";

module {

  // ═══════════════════════════════════════════════════════════════════════
  // Types
  // ═══════════════════════════════════════════════════════════════════════

  /// Result of an x402 client fetch.
  public type FetchResult = {
    #ok : { status : Nat; body : Text; paidAmount : Nat; txHash : Text };
    #free : { status : Nat; body : Text };
    #paymentFailed : Text;                  // permanent: bad sig, wrong chain, server rejection
    #httpError : { status : Nat; body : Text };
    #transientError : Text;                 // retryable: network timeout, adapter saturated
  };

  /// Cached payment info for skip-probe mode.
  /// Pass to fetchWithPayment to skip the initial 402 probe (halves outcalls).
  public type CachedPaymentInfo = {
    recipient : Text;   // 0x-prefixed payTo address
    amount : Nat;
    tokenName : Text;   // EIP-712 domain name (e.g. "USDC", "USD Coin")
    tokenVersion : Text; // EIP-712 domain version (e.g. "2")
  };

  /// Transform function type for HTTPS outcall responses.
  public type TransformFn = shared query { response : IC.HttpRequestResult; context : Blob } -> async IC.HttpRequestResult;

  // ═══════════════════════════════════════════════════════════════════════
  // Transform
  // ═══════════════════════════════════════════════════════════════════════

  /// Strip non-deterministic response headers for HTTPS outcall consensus,
  /// preserving headers needed for x402:
  ///   payment-required — payment metadata (base64 JSON)
  ///   content-length   — used to size the paid retry efficiently
  ///
  /// Use this in your actor's transform function:
  ///   public query func httpTransform(args : ...) : async ... { Ic402.X402Client.transformResponse(args.response) };
  public func transformResponse(response : IC.HttpRequestResult) : IC.HttpRequestResult {
    let kept = Array.filter<{ name : Text; value : Text }>(
      response.headers,
      func(h) {
        let n = toLower(h.name);
        n == "payment-required" or n == "content-length";
      },
    );
    { status = response.status; headers = kept; body = response.body };
  };

  /// Strip ALL response headers (use when you only need the body).
  public func stripHeaders(response : IC.HttpRequestResult) : IC.HttpRequestResult {
    { status = response.status; headers = []; body = response.body };
  };

  func toLower(t : Text) : Text {
    Text.map(t, func(c : Char) : Char {
      if (c >= 'A' and c <= 'Z') {
        Char.fromNat32(Char.toNat32(c) + 32);
      } else { c };
    });
  };

  /// Classify an error message as transient (retryable) or permanent.
  func isTransientError(msg : Text) : Bool {
    Text.contains(msg, #text "could not perform remote call") or
    Text.contains(msg, #text "timeout") or
    Text.contains(msg, #text "replica error") or
    Text.contains(msg, #text "Timeout expired") or
    Text.contains(msg, #text "no consensus");
  };

  // ═══════════════════════════════════════════════════════════════════════
  // Client
  // ═══════════════════════════════════════════════════════════════════════

  /// x402 client: pays for external x402-gated content using EIP-3009.
  public class X402Client(
    ecdsaKeyName : Text,
    preferredChainId : Nat,
    preferredToken : Text,
    transformFn : ?TransformFn,
  ) {

    var cachedPubKey : ?[Nat8] = null;
    var cachedEvmAddr : ?Text = null;
    var nonceCounter : Nat = 0; // monotonic counter — ensures unique EIP-3009 nonces

    func getPublicKey() : async [Nat8] {
      switch (cachedPubKey) {
        case (?pk) { pk };
        case (null) {
          let result = await IC.ic.ecdsa_public_key({
            key_id = { name = ecdsaKeyName; curve = #secp256k1 };
            canister_id = null;
            derivation_path = [];
          });
          let pk = Blob.toArray(result.public_key);
          cachedPubKey := ?pk;
          pk;
        };
      };
    };

    func getEvmAddress() : async Text {
      switch (cachedEvmAddr) {
        case (?addr) { addr };
        case (null) {
          let pk = await getPublicKey();
          let addr = switch (EvmAddress.fromCompressedPublicKey(pk)) {
            case (#ok(a)) { a };
            case (#err(_)) { "" };
          };
          cachedEvmAddr := ?addr;
          addr;
        };
      };
    };

    /// Debug: make a GET request and return raw response info.
    public func debugFetch(url : Text, tfn : TransformFn) : async Text {
      let response = await Call.httpRequest({
        url;
        max_response_bytes = ?(65536 : Nat64);
        method = #get;
        headers = [];
        body = null;
        transform = ?{ function = tfn; context = Blob.fromArray([]) };
      });
      var result = "status=" # Nat.toText(response.status) # " headers=" # Nat.toText(response.headers.size()) # " body=" # Nat.toText(response.body.size());
      for (h in response.headers.vals()) {
        result #= " | " # h.name # ":" # Nat.toText(h.value.size()) # "chars";
      };
      result;
    };

    /// Backward-compatible wrapper: probe + pay in one call.
    public func fetch(
      url : Text,
      method : { #get; #post },
      requestBody : ?Blob,
      extraHeaders : [{ name : Text; value : Text }],
    ) : async FetchResult {
      await fetchWithPayment(url, method, requestBody, extraHeaders, null);
    };

    /// Fetch content from an x402 endpoint. If 402, pay and retry.
    ///
    /// `cachedPayment`: pass cached payment info to skip the 402 probe
    /// (halves HTTPS outcalls). If null, probes first. If cached info is stale,
    /// returns #paymentFailed so the caller can re-probe.
    public func fetchWithPayment(
      url : Text,
      method : { #get; #post },
      requestBody : ?Blob,
      extraHeaders : [{ name : Text; value : Text }],
      cachedPayment : ?CachedPaymentInfo,
    ) : async FetchResult {
      let httpMethod = switch (method) { case (#get) { #get }; case (#post) { #post } };
      let smallRetry : Nat64 = 262_144;     // 256KB — covers most API responses cheaply
      let largeRetry : Nat64 = 2_000_000;   // 2MB — ICP max, fallback for large responses
      let transform = switch (transformFn) {
        case (?fn) { ?{ function = fn; context = Blob.fromArray([]) } };
        case (null) { null };
      };

      // ── Resolve payment option: from cache or by probing ──

      var option : ?PaymentOption = null;
      // Content-length from the 402 response, if available.
      // NOTE: Current x402 servers return the 402 body size here (typically 2
      // bytes for "{}"), NOT the paid content size. No server provides a content
      // size hint for the paid response yet. The adaptive sizing protocol
      // handles this: content-length hint → 256KB default → 2MB fallback.
      // When servers start including actual content size, this path activates
      // automatically.
      var contentLength : Nat64 = 0;

      switch (cachedPayment) {
        case (?cached) {
          // Skip probe — use cached payment info directly
          option := ?{
            recipient = EvmUtils.hexToBytes(cached.recipient);
            recipientHex = cached.recipient;
            amount = cached.amount;
            tokenName = cached.tokenName;
            tokenVersion = cached.tokenVersion;
          };
        };
        case (null) {
          // Probe: try 8KB → 64KB → 256KB.
          // Most 402 responses are <2KB. Escalate for large headers or free endpoints.
          let probeResponse = try {
            await Call.httpRequest({
              url;
              max_response_bytes = ?(8_192 : Nat64);
              method = httpMethod;
              headers = extraHeaders;
              body = requestBody;
              transform;
            });
          } catch (probeErr) {
            let msg = Error.message(probeErr);
            if (Text.contains(msg, #text "exceeds")) {
              // 8KB too small — try 64KB (covers large headers like QuickNode's 16-option 402)
              try {
                await Call.httpRequest({
                  url;
                  max_response_bytes = ?(65_536 : Nat64);
                  method = httpMethod;
                  headers = extraHeaders;
                  body = requestBody;
                  transform;
                });
              } catch (probe64Err) {
                let msg64 = Error.message(probe64Err);
                if (Text.contains(msg64, #text "exceeds")) {
                  // 64KB too small — try 256KB (large free endpoint)
                  try {
                    await Call.httpRequest({
                      url;
                      max_response_bytes = ?smallRetry;
                      method = httpMethod;
                      headers = extraHeaders;
                      body = requestBody;
                      transform;
                    });
                  } catch (retryProbeErr) {
                    let retryMsg = Error.message(retryProbeErr);
                    return if (isTransientError(retryMsg)) {
                      #transientError("Probe failed: " # retryMsg);
                    } else {
                      #paymentFailed("Probe failed: " # retryMsg);
                    };
                  };
                } else {
                  return if (isTransientError(msg64)) {
                    #transientError("Probe failed: " # msg64);
                  } else {
                    #paymentFailed("Probe failed: " # msg64);
                  };
                };
              };
            } else {
              return if (isTransientError(msg)) {
                #transientError("Probe failed: " # msg);
              } else {
                #paymentFailed("Probe failed: " # msg);
              };
            };
          };

          // If not 402, return as-is
          if (probeResponse.status != 402) {
            let bodyText = switch (Text.decodeUtf8(probeResponse.body)) {
              case (?t) { t };
              case (null) { "" };
            };
            if (probeResponse.status >= 200 and probeResponse.status < 300) {
              return #free({ status = probeResponse.status; body = bodyText });
            } else {
              return #httpError({ status = probeResponse.status; body = bodyText });
            };
          };

          // Parse 402 response — extract payment-required and content-length
          var paymentJson = "";
          for (h in probeResponse.headers.vals()) {
            let name = toLower(h.name);
            if (name == "payment-required") {
              let decoded = Utils.base64Decode(h.value);
              switch (Text.decodeUtf8(Blob.fromArray(decoded))) {
                case (?t) { paymentJson := t };
                case (null) {};
              };
            } else if (name == "content-length") {
              var n : Nat64 = 0;
              for (c in h.value.chars()) {
                let d = Char.toNat32(c);
                if (d >= 48 and d <= 57) { n := n * 10 + Nat64.fromNat(Nat32.toNat(d - 48)) };
              };
              contentLength := n;
            };
          };
          // Fall back to body for payment metadata
          if (paymentJson == "") {
            paymentJson := switch (Text.decodeUtf8(probeResponse.body)) {
              case (?t) { t };
              case (null) { return #paymentFailed("Cannot decode 402 response") };
            };
          };

          option := findPaymentOption(paymentJson);
        };
      };

      // ── Sign and pay ──

      switch (option) {
        case (null) { #paymentFailed("NO_MATCH: Server does not accept payments on eip155:" # Nat.toText(preferredChainId) # ". Check the server's supported networks.") };
        case (?opt) {
          try {
            let fromAddr = await getEvmAddress();
            let pubKey = await getPublicKey();
            let tokenAddr = EvmUtils.hexToBytes(preferredToken);
            let now : Nat = Int.abs(Time.now() / 1_000_000_000);
            let validAfter = if (now > 600) { now - 600 } else { 0 };
            let validBefore = now + 300;
            // EIP-3009 nonce: timestamp + counter ensures uniqueness across calls
            // and across canister upgrades (timestamp prevents reuse after restart)
            nonceCounter += 1;
            let nonceBytes = EvmUtils.natToBytes(now * 1_000_000 + nonceCounter, 32);

            // EIP-712 digest
            let domSep = Eip712.domainSeparator(opt.tokenName, opt.tokenVersion, preferredChainId, tokenAddr);
            let structHash = Eip712.hashTransferWithAuthorization(
              EvmUtils.hexToBytes(fromAddr), opt.recipient, opt.amount, validAfter, validBefore, nonceBytes,
            );
            let digest = Eip712.digest(domSep, structHash);

            // Sign with tECDSA
            let signResult = await Call.signWithEcdsa({
              key_id = { name = ecdsaKeyName; curve = #secp256k1 };
              derivation_path = [];
              message_hash = Blob.fromArray(digest);
            });
            let sigBytes = Blob.toArray(signResult.signature);
            let r = Array.subArray(sigBytes, 0, 32);
            let s = Array.subArray(sigBytes, 32, 32);
            let v = EvmAddress.recoverYParity(digest, r, s, pubKey);

            // Build x402 v2 payment header
            let sigHex = EvmUtils.bytesToHex(Array.append(Array.append(r, s), [v + 27]));
            let networkStr = "eip155:" # Nat.toText(preferredChainId);
            let paymentPayload = "{\"x402Version\":2"
              # ",\"resource\":{\"url\":\"" # Utils.escapeJsonString(url) # "\"}"
              # ",\"accepted\":{\"scheme\":\"exact\""
              # ",\"network\":\"" # networkStr # "\""
              # ",\"amount\":\"" # Nat.toText(opt.amount) # "\""
              # ",\"asset\":\"" # preferredToken # "\""
              # ",\"payTo\":\"" # opt.recipientHex # "\""
              # ",\"maxTimeoutSeconds\":300"
              # ",\"extra\":{\"name\":\"" # Utils.escapeJsonString(opt.tokenName) # "\",\"version\":\"" # Utils.escapeJsonString(opt.tokenVersion) # "\"}}"
              # ",\"payload\":{\"signature\":\"" # sigHex # "\""
              # ",\"authorization\":{\"from\":\"" # fromAddr # "\""
              # ",\"to\":\"" # opt.recipientHex # "\""
              # ",\"value\":\"" # Nat.toText(opt.amount) # "\""
              # ",\"validAfter\":\"" # Nat.toText(validAfter) # "\""
              # ",\"validBefore\":\"" # Nat.toText(validBefore) # "\""
              # ",\"nonce\":\"" # EvmUtils.bytesToHex(nonceBytes) # "\""
              # "}}}";
            let base64Header = Utils.base64Encode(Blob.toArray(Text.encodeUtf8(paymentPayload)));

            // Paid retry — adaptive sizing to minimize cycle cost
            let retryHeaders = Array.append(extraHeaders, [
              { name = "Payment-Signature"; value = base64Header },
              { name = "X-Payment"; value = base64Header },
            ]);

            // Size the retry: content-length hint → 256KB default → 2MB fallback
            let retryLimit : Nat64 = if (contentLength > 0) {
              let withMargin = contentLength + contentLength / 5 + 4096;
              if (withMargin > largeRetry) { largeRetry } else { withMargin };
            } else { smallRetry };

            var retryResponse = try {
              await Call.httpRequest({
                url;
                max_response_bytes = ?retryLimit;
                method = httpMethod;
                headers = retryHeaders;
                body = requestBody;
                transform;
              });
            } catch (retryErr) {
              let errMsg = Error.message(retryErr);
              if (Text.contains(errMsg, #text "exceeds") and retryLimit < largeRetry) {
                // Response larger than estimate — fall back to 2MB max
                await Call.httpRequest({
                  url;
                  max_response_bytes = ?largeRetry;
                  method = httpMethod;
                  headers = retryHeaders;
                  body = requestBody;
                  transform;
                });
              } else if (isTransientError(errMsg)) {
                return #transientError("Paid retry failed: " # errMsg);
              } else {
                throw retryErr;
              };
            };

            let retryBody = switch (Text.decodeUtf8(retryResponse.body)) {
              case (?t) { t };
              case (null) { "" };
            };

            if (retryResponse.status >= 200 and retryResponse.status < 300) {
              #ok({
                status = retryResponse.status;
                body = retryBody;
                paidAmount = opt.amount;
                txHash = sigHex;
              });
            } else if (retryResponse.status == 402) {
              // Server returned 402 even with payment — include response body for diagnostics
              #paymentFailed("SETTLEMENT_FAILED: Facilitator rejected the on-chain transfer. " # retryBody);
            } else {
              #paymentFailed("SERVER_ERROR: Payment sent but server returned HTTP " # Nat.toText(retryResponse.status) # ". " # retryBody);
            };
          } catch (e) {
            let msg = Error.message(e);
            if (isTransientError(msg)) {
              #transientError(msg);
            } else {
              #paymentFailed("SIGN_ERROR: Failed to sign or submit payment. " # msg);
            };
          };
        };
      };
    };

    // ═══════════════════════════════════════════════════════════════════════
    // Payment option parsing
    // ═══════════════════════════════════════════════════════════════════════

    type PaymentOption = {
      recipient : [Nat8];
      recipientHex : Text;
      amount : Nat;
      tokenName : Text;
      tokenVersion : Text;
    };

    /// Map chain IDs to common non-standard network names used by some x402 servers.
    func chainAlias(chainId : Nat) : Text {
      switch (chainId) {
        case (8453)     { "base" };
        case (84532)    { "base-sepolia" };
        case (1)        { "ethereum" };
        case (11155111) { "ethereum-sepolia" };
        case (43114)    { "avalanche" };
        case (43113)    { "avalanche-fuji" };
        case (10)       { "optimism" };
        case (11155420) { "optimism-sepolia" };
        case (42161)    { "arbitrum" };
        case (421614)   { "arbitrum-sepolia" };
        case (_)        { "" };
      };
    };

    func findPaymentOption(body : Text) : ?PaymentOption {
      // Match by CAIP-2 network string (standard) or common alias (non-standard).
      // When multiple accepts entries exist for the same network (e.g. QuickNode
      // offers both $1 and $0.001 options), pick the cheapest one.
      let networkStr = "eip155:" # Nat.toText(preferredChainId);
      let alias = chainAlias(preferredChainId);
      let networkNeedle = "\"network\":\"" # networkStr # "\"";
      let aliasNeedle = if (alias != "") { "\"network\":\"" # alias # "\"" } else { "" };

      // Find all accepts entries matching our network by splitting on the network needle.
      // For each match, extract fields from the surrounding text (the accepts entry).
      var bestOption : ?PaymentOption = null;
      var bestAmount : Nat = 0xFFFFFFFFFFFFFFFF; // max Nat64

      // Try both standard and alias network strings
      let needles = if (aliasNeedle != "") { [networkNeedle, aliasNeedle] } else { [networkNeedle] };
      for (needle in needles.vals()) {
        // Split body on the needle to find each occurrence
        let parts = Text.split(body, #text needle);
        var first = true;
        for (part in parts) {
          if (first) { first := false } // skip text before first match
          else {
            // `part` starts right after the network field. Extract fields from this entry.
            // Look backward from the split point too — prepend some preceding text.
            // Since we split on the network field, payTo/amount should be nearby in the same entry.
            let entry = part;
            let payTo = Utils.extractJsonField(entry, "payTo");
            var amount = Utils.extractJsonNatField(entry, "maxAmountRequired");
            if (amount == 0) { amount := Utils.extractJsonNatField(entry, "amount") };

            if (payTo != "" and amount > 0 and amount < bestAmount) {
              let nameField = Utils.extractJsonField(entry, "name");
              let tokenName = if (nameField == "") { "USD Coin" } else { nameField };
              let versionField = Utils.extractJsonField(entry, "version");
              let tokenVersion = if (versionField == "") { "2" } else { versionField };

              bestAmount := amount;
              bestOption := ?{
                recipient = EvmUtils.hexToBytes(payTo);
                recipientHex = payTo;
                amount;
                tokenName;
                tokenVersion;
              };
            };
          };
        };
      };
      bestOption;
    };
  };
};
