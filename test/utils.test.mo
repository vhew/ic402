/// Motoko unit tests for Utils module.
import Utils "../src/ic402/Utils";
import { test; suite } "mo:test";

suite("Utils", func() {

  // ── natToBytes8 ──

  suite("natToBytes8", func() {

    test("zero produces 8 zero bytes", func() {
      let bytes = Utils.natToBytes8(0);
      assert(bytes.size() == 8);
      for (b in bytes.vals()) { assert(b == 0) };
    });

    test("1 encodes correctly", func() {
      let bytes = Utils.natToBytes8(1);
      assert(bytes[7] == 1);
      assert(bytes[6] == 0);
    });

    test("255 encodes correctly", func() {
      let bytes = Utils.natToBytes8(255);
      assert(bytes[7] == 255);
      assert(bytes[6] == 0);
    });

    test("256 encodes correctly", func() {
      let bytes = Utils.natToBytes8(256);
      assert(bytes[7] == 0);
      assert(bytes[6] == 1);
    });

    test("known big-endian output for 0x0102030405060708", func() {
      // 0x0102030405060708 = 72623859790382856
      let bytes = Utils.natToBytes8(72623859790382856);
      assert(bytes[0] == 1);
      assert(bytes[1] == 2);
      assert(bytes[2] == 3);
      assert(bytes[3] == 4);
      assert(bytes[4] == 5);
      assert(bytes[5] == 6);
      assert(bytes[6] == 7);
      assert(bytes[7] == 8);
    });

    test("max Nat64 (2^64 - 1)", func() {
      let bytes = Utils.natToBytes8(18_446_744_073_709_551_615);
      for (b in bytes.vals()) { assert(b == 255) };
    });
  });

  // ── toLower ──

  suite("toLower", func() {

    test("converts uppercase to lowercase", func() {
      assert(Utils.toLower("HELLO") == "hello");
    });

    test("mixed case", func() {
      assert(Utils.toLower("Hello World") == "hello world");
    });

    test("already lowercase passthrough", func() {
      assert(Utils.toLower("hello") == "hello");
    });

    test("non-ASCII passthrough", func() {
      assert(Utils.toLower("café") == "café");
    });
  });

  // ── extractJsonField ──

  suite("extractJsonField", func() {

    test("basic field extraction", func() {
      let json = "{\"name\":\"alice\",\"age\":\"30\"}";
      assert(Utils.extractJsonField(json, "name") == "alice");
      assert(Utils.extractJsonField(json, "age") == "30");
    });

    test("handles escaped quotes in value", func() {
      let json = "{\"msg\":\"hello \\\"world\\\"\"}";
      assert(Utils.extractJsonField(json, "msg") == "hello \"world\"");
    });

    test("missing field returns empty string", func() {
      let json = "{\"name\":\"alice\"}";
      assert(Utils.extractJsonField(json, "missing") == "");
    });

    test("nested objects don't confuse parser", func() {
      let json = "{\"outer\":\"value\",\"nested\":\"{inner}\"}";
      assert(Utils.extractJsonField(json, "outer") == "value");
    });

    test("M-10: unescapes \\\" \\\\ \\n \\t", func() {
      let json = "{\"data\":\"a\\\"b\\\\c\\nd\\te\"}";
      let result = Utils.extractJsonField(json, "data");
      assert(result == "a\"b\\c\nd\te");
    });
  });

  // ── escapeJsonString ──

  suite("escapeJsonString", func() {

    test("escapes double quote", func() {
      assert(Utils.escapeJsonString("say \"hi\"") == "say \\\"hi\\\"");
    });

    test("escapes backslash", func() {
      assert(Utils.escapeJsonString("a\\b") == "a\\\\b");
    });

    test("escapes newline", func() {
      assert(Utils.escapeJsonString("line1\nline2") == "line1\\nline2");
    });

    test("escapes tab", func() {
      assert(Utils.escapeJsonString("col1\tcol2") == "col1\\tcol2");
    });

    test("escapes carriage return", func() {
      assert(Utils.escapeJsonString("a\rb") == "a\\rb");
    });

    test("clean string passthrough", func() {
      assert(Utils.escapeJsonString("hello world") == "hello world");
    });
  });
});
