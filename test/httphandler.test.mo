/// Motoko unit tests for HttpHandler module.
import HttpHandler "../src/ic402/HttpHandler";
import Types "../src/ic402/Types";
import Text "mo:base/Text";
import Blob "mo:base/Blob";
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
      let json = HttpHandler.paymentRequiredJson(reqs);
      assert(Text.contains(json, #text "\"x402Version\":1"));
      assert(Text.contains(json, #text "\"scheme\":\"exact\""));
      assert(Text.contains(json, #text "\"network\":\"icp:1\""));
      assert(Text.contains(json, #text "\"maxAmountRequired\":\"1000\""));
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
      let json = HttpHandler.paymentRequiredJson(reqs);
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
      let json = HttpHandler.paymentRequiredJson(reqs);
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
});
