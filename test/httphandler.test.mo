/// Motoko unit tests for HttpHandler module.
///
/// The "x402 v2 wire goldens" suite pins ic402's x402 wire format against the OFFICIAL
/// reference implementation (github.com/x402-foundation/x402, the current home of
/// Coinbase's x402 project) — @x402/core@2.17.0 + @x402/evm@2.17.0 + @x402/fetch@2.17.0,
/// signatures via viem@2.55.0. The same fixtures live in test/fixtures/x402/* and are
/// validated against the official v2 zod schemas by test/x402-conformance.test.ts.
import HttpHandler "../src/ic402/HttpHandler";
import Types "../src/ic402/Types";
import Text "mo:base/Text";
import Blob "mo:base/Blob";
import Array "mo:base/Array";
import Nat8 "mo:base/Nat8";
import { test; suite } "mo:test";

suite("HttpHandler", func() {

  // ── getPath ──

  suite("getPath", func() {

    test("basic path", func() {
      assert(HttpHandler.getPath("/content/abc") == "/content/abc");
    });

    test("path with query string", func() {
      assert(HttpHandler.getPath("/search?q=hello&limit=10") == "/search");
    });

    test("root path", func() {
      assert(HttpHandler.getPath("/") == "/");
    });

    test("no query returns full URL", func() {
      assert(HttpHandler.getPath("/a/b/c") == "/a/b/c");
    });
  });

  // ── getQueryParam ──

  suite("getQueryParam", func() {

    test("present param", func() {
      switch (HttpHandler.getQueryParam("/search?q=hello", "q")) {
        case (?v) { assert(v == "hello") };
        case (null) { assert(false) };
      };
    });

    test("missing param", func() {
      switch (HttpHandler.getQueryParam("/search?q=hello", "limit")) {
        case (null) {};
        case (?_) { assert(false) };
      };
    });

    test("multiple params", func() {
      switch (HttpHandler.getQueryParam("/search?q=hello&limit=10", "limit")) {
        case (?v) { assert(v == "10") };
        case (null) { assert(false) };
      };
    });

    test("no query string", func() {
      switch (HttpHandler.getQueryParam("/search", "q")) {
        case (null) {};
        case (?_) { assert(false) };
      };
    });
  });

  // ── getHeader ──

  suite("getHeader", func() {

    test("case-insensitive match", func() {
      let headers = [("Content-Type", "application/json"), ("X-Custom", "value")];
      switch (HttpHandler.getHeader(headers, "content-type")) {
        case (?v) { assert(v == "application/json") };
        case (null) { assert(false) };
      };
    });

    test("missing header", func() {
      let headers = [("Content-Type", "application/json")];
      switch (HttpHandler.getHeader(headers, "Authorization")) {
        case (null) {};
        case (?_) { assert(false) };
      };
    });
  });

  // ── paymentRequiredJson ──

  suite("paymentRequiredJson", func() {

    test("single requirement", func() {
      let reqs : [Types.PaymentRequirement] = [{
        scheme = "exact";
        network = "icp:1";
        token = "ryjl3-tyaaa-aaaaa-aaaba-cai";
        amount = 1000;
        recipient = "abc123";
        nonce = Blob.fromArray([1, 2, 3]);
        expiry = 0;
        tokenName = null;
        tokenVersion = null;
      }];
      let json = HttpHandler.paymentRequiredJson(reqs, "https://host/content/x", null);
      assert(Text.contains(json, #text "\"x402Version\":2"));
      assert(Text.contains(json, #text "\"scheme\":\"exact\""));
      assert(Text.contains(json, #text "\"network\":\"icp:1\""));
      // v2 renames maxAmountRequired -> amount
      assert(Text.contains(json, #text "\"amount\":\"1000\""));
      assert(not Text.contains(json, #text "maxAmountRequired"));
      // v2 PaymentRequired carries ResourceInfo + default asset-transfer method
      assert(Text.contains(json, #text "\"resource\":{\"url\":\"https://host/content/x\"}"));
      assert(Text.contains(json, #text "\"assetTransferMethod\":\"eip3009\""));
    });

    test("multiple requirements", func() {
      let reqs : [Types.PaymentRequirement] = [
        {
          scheme = "exact"; network = "icp:1";
          token = "ledger-a"; amount = 100; recipient = "a";
          nonce = Blob.fromArray([1]); expiry = 0;
          tokenName = null; tokenVersion = null;
        },
        {
          scheme = "exact"; network = "eip155:8453";
          token = "0xusdc"; amount = 200; recipient = "b";
          nonce = Blob.fromArray([2]); expiry = 0;
          tokenName = null; tokenVersion = null;
        },
      ];
      let json = HttpHandler.paymentRequiredJson(reqs, "https://host/r", null);
      // Should contain comma-separated accepts
      assert(Text.contains(json, #text "\"accepts\":[{"));
      assert(Text.contains(json, #text "},{"));
    });

    test("escaping in field values (M-4)", func() {
      let reqs : [Types.PaymentRequirement] = [{
        scheme = "exact";
        network = "test\"net";
        token = "tok\\en";
        amount = 1;
        recipient = "rec\nip";
        nonce = Blob.fromArray([]);
        expiry = 0;
        tokenName = null;
        tokenVersion = null;
      }];
      let json = HttpHandler.paymentRequiredJson(reqs, "https://host/r", null);
      // Escaped values should be present, raw ones should not
      assert(Text.contains(json, #text "test\\\"net"));
      assert(Text.contains(json, #text "tok\\\\en"));
      assert(Text.contains(json, #text "rec\\nip"));
    });
  });

  // ── httpError ──

  suite("httpError", func() {

    test("404 status code", func() {
      let resp = HttpHandler.httpError(404, "Not found");
      assert(resp.status_code == 404);
    });

    test("500 status code", func() {
      let resp = HttpHandler.httpError(500, "Internal error");
      assert(resp.status_code == 500);
    });

    test("message escaping (M-4)", func() {
      let resp = HttpHandler.httpError(400, "bad \"input\"");
      let body = Text.decodeUtf8(resp.body);
      switch (body) {
        case (?text) {
          assert(Text.contains(text, #text "bad \\\"input\\\""));
        };
        case (null) { assert(false) };
      };
    });
  });

  // ── http202JsonWithSettlement (2.6.2 additive) ──

  suite("http202JsonWithSettlement", func() {

    test("202 + PAYMENT-RESPONSE header + JSON body (mirrors the 200 variant)", func() {
      let resp = HttpHandler.http202JsonWithSettlement("{\"jobId\":\"job-1\"}", "{\"success\":true}");
      assert(resp.status_code == 202);
      assert(resp.body == Text.encodeUtf8("{\"jobId\":\"job-1\"}"));
      var hasSettlement = false;
      var hasJsonType = false;
      for ((k, v) in resp.headers.vals()) {
        if (k == "PAYMENT-RESPONSE") { hasSettlement := true };
        if (k == "Content-Type" and v == "application/json") { hasJsonType := true };
      };
      assert(hasSettlement);
      assert(hasJsonType);
    });
  });

  // ── x402 v2 wire goldens ──
  //
  // GOLDEN WIRE VECTORS, cross-boundary discipline (like the voucher/selfauth goldens):
  //
  // OUTBOUND (402 emission): the exact PaymentRequired bytes HttpHandler emits for fixed
  // inputs. The live-challenge golden is stored byte-identically (compact form) in
  // test/fixtures/x402/payment-required.golden.json and validated against the OFFICIAL
  // @x402/core@2.17.0 zod schemas (PaymentRequiredV2Schema / PaymentRequirementsV2Schema)
  // by test/x402-conformance.test.ts — change either side and the other fails.
  //
  // INBOUND (header parse): the REAL PAYMENT-SIGNATURE header produced by the official
  // Coinbase/x402-foundation CLIENT packages — @x402/core@2.17.0 x402Client.createPaymentPayload
  // + @x402/evm@2.17.0 ExactEvmScheme (EIP-3009 TransferWithAuthorization typed data signed via
  // viem@2.55.0 by the test key 0x0707…07 → payer 0x4a62316623ad457F02cDC5D997deD67a383EC569).
  // Generation was made deterministic by pinning Date.now()=1750000000000 and
  // crypto.getRandomValues=0x42-fill BEFORE package import, so validBefore=1750000300 and
  // authorization.nonce=0x42×32 are stable. Same base64 literal as
  // test/fixtures/x402/payment-header.golden.txt (decoded: payment-payload.golden.json).
  //
  // DETERMINISM: Time.now() inside `mops test` is a CONSTANT fake clock — 42 ns in the
  // current toolchain (not wall time) — so `expiry` values below fully determine the
  // emitted maxTimeoutSeconds and the goldens are byte-stable. The live-challenge expiry
  // is 300_000_000_042 = fake-now(42) + 300 s, which floors to exactly 300 for a fake
  // clock of 42 AND of 0 (any other constant re-pins loudly).

  suite("x402 v2 wire goldens", func() {

    let SEPOLIA_USDC = "0x036CbD53842c5426634e7929541eC2318f3dCF7e"; // Base Sepolia USDC (FiatToken v2.2)
    let BASE_USDC = "0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913"; // Base mainnet USDC
    let PAY_TO = "0x99C851eaa3c3976914D63b822C67e201EC0BFBb8"; // viem key 0x0808…08
    // 32-byte ic402 server nonce, hex a1b2c3d4e5f60718293a4b5c6d7e8f90 ×2
    let SERVER_NONCE : [Nat8] = [0xa1, 0xb2, 0xc3, 0xd4, 0xe5, 0xf6, 0x07, 0x18, 0x29, 0x3a, 0x4b, 0x5c, 0x6d, 0x7e, 0x8f, 0x90, 0xa1, 0xb2, 0xc3, 0xd4, 0xe5, 0xf6, 0x07, 0x18, 0x29, 0x3a, 0x4b, 0x5c, 0x6d, 0x7e, 0x8f, 0x90];

    func sepoliaReq(nonce : [Nat8], expiry : Int, tokenName : ?Text) : Types.PaymentRequirement {
      {
        scheme = "exact";
        network = "eip155:84532";
        token = SEPOLIA_USDC;
        amount = 10000;
        recipient = PAY_TO;
        nonce = Blob.fromArray(nonce);
        expiry;
        tokenName;
        tokenVersion = null;
      };
    };

    // MUST MATCH test/fixtures/x402/payment-required.golden.json (compact form) — the file
    // is schema-validated against the official @x402/core@2.17.0 PaymentRequiredV2Schema by
    // test/x402-conformance.test.ts.
    let GOLDEN_402_LIVE = "{\"x402Version\":2,\"error\":\"PAYMENT-SIGNATURE header is required\",\"resource\":{\"url\":\"https://example-canister.icp0.io/content/premium-1\"},\"accepts\":[{\"scheme\":\"exact\",\"network\":\"eip155:84532\",\"amount\":\"10000\",\"asset\":\"0x036CbD53842c5426634e7929541eC2318f3dCF7e\",\"payTo\":\"0x99C851eaa3c3976914D63b822C67e201EC0BFBb8\",\"maxTimeoutSeconds\":300,\"extra\":{\"name\":\"USDC\",\"version\":\"2\",\"assetTransferMethod\":\"eip3009\",\"ic402Nonce\":\"a1b2c3d4e5f60718293a4b5c6d7e8f90a1b2c3d4e5f60718293a4b5c6d7e8f90\",\"ic402Expiry\":300000000042}}]}";

    test("live challenge (expiry > now): byte-exact PaymentRequired, tokenName fallback USDC", func() {
      // tokenName = null on Base Sepolia USDC → the EIP-712 domain-name fallback must
      // yield "USDC" (FiatToken v2.2), NOT "USD Coin" — a wrong domain name makes every
      // transferWithAuthorization revert with an invalid signature.
      let reqs : [Types.PaymentRequirement] = [sepoliaReq(SERVER_NONCE, 300_000_000_042, null)];
      let json = HttpHandler.paymentRequiredJson(reqs, "https://example-canister.icp0.io/content/premium-1", ?"PAYMENT-SIGNATURE header is required");
      assert(json == GOLDEN_402_LIVE);
    });

    test("discovery/describe (expiry == 0): maxTimeoutSeconds falls back to 300, never 0", func() {
      // Gateway.describe/describeAll list resources with nonce = empty, expiry = 0. The
      // official PaymentRequirementsV2Schema requires maxTimeoutSeconds to be strictly
      // POSITIVE — a 0 makes a stock v2 client reject the whole PaymentRequired, so the
      // no-live-nonce listing advertises the standard 300 s challenge window instead.
      let json = HttpHandler.acceptsArrayJson([sepoliaReq([], 0, null)]);
      assert(json == "[{\"scheme\":\"exact\",\"network\":\"eip155:84532\",\"amount\":\"10000\",\"asset\":\"0x036CbD53842c5426634e7929541eC2318f3dCF7e\",\"payTo\":\"0x99C851eaa3c3976914D63b822C67e201EC0BFBb8\",\"maxTimeoutSeconds\":300,\"extra\":{\"name\":\"USDC\",\"version\":\"2\",\"assetTransferMethod\":\"eip3009\",\"ic402Nonce\":\"\",\"ic402Expiry\":0}}]");
    });

    test("unconfigured tokenName on a non-Base-Sepolia-USDC asset falls back to \"USD Coin\"", func() {
      // Base MAINNET USDC's EIP-712 domain name genuinely is "USD Coin" — the generic
      // fallback stays correct there.
      let json = HttpHandler.acceptsArrayJson([{
        scheme = "exact";
        network = "eip155:8453";
        token = BASE_USDC;
        amount = 10000;
        recipient = PAY_TO;
        nonce = Blob.fromArray([]);
        expiry = 0;
        tokenName = null;
        tokenVersion = null;
      }]);
      assert(json == "[{\"scheme\":\"exact\",\"network\":\"eip155:8453\",\"amount\":\"10000\",\"asset\":\"0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913\",\"payTo\":\"0x99C851eaa3c3976914D63b822C67e201EC0BFBb8\",\"maxTimeoutSeconds\":300,\"extra\":{\"name\":\"USD Coin\",\"version\":\"2\",\"assetTransferMethod\":\"eip3009\",\"ic402Nonce\":\"\",\"ic402Expiry\":0}}]");
    });

    test("USDC fallback is case-insensitive on the asset address", func() {
      let json = HttpHandler.acceptsArrayJson([{
        scheme = "exact";
        network = "eip155:84532";
        token = "0x036cbd53842c5426634e7929541ec2318f3dcf7e"; // lowercase form
        amount = 10000;
        recipient = PAY_TO;
        nonce = Blob.fromArray([]);
        expiry = 0;
        tokenName = null;
        tokenVersion = null;
      }]);
      assert(Text.contains(json, #text "\"name\":\"USDC\""));
    });

    test("configured tokenName always wins over the fallback", func() {
      let json = HttpHandler.acceptsArrayJson([sepoliaReq([], 0, ?"CustomToken")]);
      assert(Text.contains(json, #text "\"name\":\"CustomToken\""));
      assert(not Text.contains(json, #text "\"name\":\"USDC\""));
    });

    test("sub-second / expired windows floor maxTimeoutSeconds at 1 (schema .positive())", func() {
      // 0.999999999 s remaining: integer ns→s division floors to 0 — must emit 1, not 0.
      let sub = HttpHandler.acceptsArrayJson([sepoliaReq(SERVER_NONCE, 999_999_999, null)]);
      assert(sub == "[{\"scheme\":\"exact\",\"network\":\"eip155:84532\",\"amount\":\"10000\",\"asset\":\"0x036CbD53842c5426634e7929541eC2318f3dCF7e\",\"payTo\":\"0x99C851eaa3c3976914D63b822C67e201EC0BFBb8\",\"maxTimeoutSeconds\":1,\"extra\":{\"name\":\"USDC\",\"version\":\"2\",\"assetTransferMethod\":\"eip3009\",\"ic402Nonce\":\"a1b2c3d4e5f60718293a4b5c6d7e8f90a1b2c3d4e5f60718293a4b5c6d7e8f90\",\"ic402Expiry\":999999999}}]");
      // Already-expired challenge (expiry < now): still strictly positive.
      let expired = HttpHandler.acceptsArrayJson([sepoliaReq(SERVER_NONCE, -1_000_000_000, null)]);
      assert(Text.contains(expired, #text "\"maxTimeoutSeconds\":1,"));
      assert(not Text.contains(expired, #text "\"maxTimeoutSeconds\":0"));
    });

    // THE REAL OFFICIAL-CLIENT HEADER. Produced by @x402/core@2.17.0 x402Client.createPaymentPayload
    // + @x402/evm@2.17.0 ExactEvmScheme.createPaymentPayload (EIP-3009 typed data, viem@2.55.0
    // signTypedData) with signing key 0x0707…07, against the reference 402 above. Same literal as
    // test/fixtures/x402/payment-header.golden.txt; decoded JSON (745 bytes) in
    // test/fixtures/x402/payment-payload.golden.json. Key order: {x402Version,payload,resource,accepted}.
    let OFFICIAL_HEADER = "eyJ4NDAyVmVyc2lvbiI6MiwicGF5bG9hZCI6eyJhdXRob3JpemF0aW9uIjp7ImZyb20iOiIweDRhNjIzMTY2MjNhZDQ1N0YwMmNEQzVEOTk3ZGVENjdhMzgzRUM1NjkiLCJ0byI6IjB4OTlDODUxZWFhM2MzOTc2OTE0RDYzYjgyMkM2N2UyMDFFQzBCRkJiOCIsInZhbHVlIjoiMTAwMDAiLCJ2YWxpZEFmdGVyIjoiMCIsInZhbGlkQmVmb3JlIjoiMTc1MDAwMDMwMCIsIm5vbmNlIjoiMHg0MjQyNDI0MjQyNDI0MjQyNDI0MjQyNDI0MjQyNDI0MjQyNDI0MjQyNDI0MjQyNDI0MjQyNDI0MjQyNDI0MjQyIn0sInNpZ25hdHVyZSI6IjB4YTYzNzJlMTQ3MjE1Mzk2NmJhZmIxMWU4Y2RlMmJiMDQwMzRjZTRiMjg0ZmIyZmJjOWE4M2RmMjZhYTBlYmMwNDQwZTlhM2JjNThkMDQ3OWE3Mjc3YjllYmM2M2FhZTU2Yjk5MjAyMTFiNDY2MGY4ODYyNTIzN2YwMTgzMjM5ZDYxYyJ9LCJyZXNvdXJjZSI6eyJ1cmwiOiJodHRwczovL2V4YW1wbGUtY2FuaXN0ZXIuaWNwMC5pby9jb250ZW50L3ByZW1pdW0tMSJ9LCJhY2NlcHRlZCI6eyJzY2hlbWUiOiJleGFjdCIsIm5ldHdvcmsiOiJlaXAxNTU6ODQ1MzIiLCJhbW91bnQiOiIxMDAwMCIsImFzc2V0IjoiMHgwMzZDYkQ1Mzg0MmM1NDI2NjM0ZTc5Mjk1NDFlQzIzMThmM2RDRjdlIiwicGF5VG8iOiIweDk5Qzg1MWVhYTNjMzk3NjkxNEQ2M2I4MjJDNjdlMjAxRUMwQkZCYjgiLCJtYXhUaW1lb3V0U2Vjb25kcyI6MzAwLCJleHRyYSI6eyJuYW1lIjoiVVNEQyIsInZlcnNpb24iOiIyIn19fQ==";

    // r ∥ s of the official 65-byte signature 0xa6372e…9d61c (v = 0x1c).
    let SIG_R : [Nat8] = [0xa6, 0x37, 0x2e, 0x14, 0x72, 0x15, 0x39, 0x66, 0xba, 0xfb, 0x11, 0xe8, 0xcd, 0xe2, 0xbb, 0x04, 0x03, 0x4c, 0xe4, 0xb2, 0x84, 0xfb, 0x2f, 0xbc, 0x9a, 0x83, 0xdf, 0x26, 0xaa, 0x0e, 0xbc, 0x04];
    let SIG_S : [Nat8] = [0x40, 0xe9, 0xa3, 0xbc, 0x58, 0xd0, 0x47, 0x9a, 0x72, 0x77, 0xb9, 0xeb, 0xc6, 0x3a, 0xae, 0x56, 0xb9, 0x92, 0x02, 0x11, 0xb4, 0x66, 0x0f, 0x88, 0x62, 0x52, 0x37, 0xf0, 0x18, 0x32, 0x39, 0xd6];

    test("parses the REAL official-client PAYMENT-SIGNATURE header field-for-field", func() {
      switch (HttpHandler.parseX402PaymentHeader(OFFICIAL_HEADER)) {
        case (?sig) {
          // From the echoed `accepted` PaymentRequirements
          assert(sig.scheme == "exact");
          assert(sig.network == "eip155:84532");
          assert(sig.asset == ?"0x036CbD53842c5426634e7929541eC2318f3dCF7e");
          // sender ← payload.authorization.from (the 0x0707…07 key's address)
          assert(sig.sender == "0x4a62316623ad457F02cDC5D997deD67a383EC569");
          // A stock v2 client echoes no ic402Nonce → EMPTY server nonce (the EVM rail then
          // binds via value == amount exact-equality, not the server nonce).
          assert(sig.nonce == Blob.fromArray([]));
          assert(sig.signature == Blob.fromArray([]));
          assert(sig.publicKey == null);
          switch (sig.authorization) {
            case (?auth) {
              assert(auth.from == "0x4a62316623ad457F02cDC5D997deD67a383EC569");
              // EIP-55 checksummed `to` — address comparison happens later on decoded bytes
              assert(auth.to == "0x99C851eaa3c3976914D63b822C67e201EC0BFBb8");
              assert(auth.value == 10000);
              assert(auth.validAfter == 0);
              assert(auth.validBefore == 1750000300);
              // authorization.nonce = 0x42×32 (pinned crypto.getRandomValues at generation)
              assert(auth.nonce == Blob.fromArray(Array.tabulate<Nat8>(32, func(_) = 0x42)));
              assert(auth.v == 1); // wire v = 0x1c (28) → internal recovery id 1
              assert(auth.r == Blob.fromArray(SIG_R));
              assert(auth.s == Blob.fromArray(SIG_S));
            };
            case (null) { assert(false) };
          };
        };
        case (null) { assert(false) };
      };
    });
  });
});
