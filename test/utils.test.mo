/// Motoko unit tests for Utils module.
///
/// Base64 GOLDEN VECTORS: every base64 literal below was produced by Node v26.5.0
/// Buffer.from(...).toString('base64') / Buffer.from(..., 'base64') (built-in, no npm deps)
/// and re-verified with `node -e` against the fixture set in the codec-characterization run
/// (goldens/base64/gen.mjs + fixtures.json). They pin the cross-boundary contract with
/// lenient upstream decoders (Node, browsers, x402 facilitators) after the 2026-07 strict
/// rewrite of Utils.base64Decode: the encoder emits padded standard-alphabet RFC 4648
/// output byte-identical to Node; the decoder whole-input-rejects ([]) anything a lenient
/// decoder would strip-and-realign, closing the parser-differential (smuggling) surface.
import Utils "../src/ic402/Utils";
import Array "mo:base/Array";
import Blob "mo:base/Blob";
import Nat8 "mo:base/Nat8";
import Text "mo:base/Text";
import { test; suite } "mo:test";

func eqBytes(a : [Nat8], b : [Nat8]) : Bool = Array.equal<Nat8>(a, b, Nat8.equal);
func utf8(t : Text) : [Nat8] = Blob.toArray(Text.encodeUtf8(t));

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

  // ── base64 ──

  /// RFC 4648 section-10 test vectors, both directions.
  /// Encoder golden = Node v26.5.0 Buffer.from(s,'utf8').toString('base64') — padded,
  /// standard alphabet. Decoder must accept BOTH the padded and the unpadded form of
  /// each vector (unpadded acceptance is part of the strict-decoder contract: the final
  /// 2-/3-char group decodes without synthesized '=').
  suite("base64 RFC 4648 vectors", func() {

    test("encode: section-10 vectors, padded standard-alphabet output", func() {
      assert(Utils.base64Encode(utf8("")) == "");
      assert(Utils.base64Encode(utf8("f")) == "Zg==");
      assert(Utils.base64Encode(utf8("fo")) == "Zm8=");
      assert(Utils.base64Encode(utf8("foo")) == "Zm9v");
      assert(Utils.base64Encode(utf8("foob")) == "Zm9vYg==");
      assert(Utils.base64Encode(utf8("fooba")) == "Zm9vYmE=");
      assert(Utils.base64Encode(utf8("foobar")) == "Zm9vYmFy");
    });

    test("decode: padded forms recover the exact UTF-8 bytes", func() {
      assert(eqBytes(Utils.base64Decode(""), utf8("")));
      assert(eqBytes(Utils.base64Decode("Zg=="), utf8("f")));
      assert(eqBytes(Utils.base64Decode("Zm8="), utf8("fo")));
      assert(eqBytes(Utils.base64Decode("Zm9v"), utf8("foo")));
      assert(eqBytes(Utils.base64Decode("Zm9vYg=="), utf8("foob")));
      assert(eqBytes(Utils.base64Decode("Zm9vYmE="), utf8("fooba")));
      assert(eqBytes(Utils.base64Decode("Zm9vYmFy"), utf8("foobar")));
    });

    test("decode: unpadded forms are accepted and decode identically", func() {
      assert(eqBytes(Utils.base64Decode("Zg"), utf8("f")));
      assert(eqBytes(Utils.base64Decode("Zm8"), utf8("fo")));
      assert(eqBytes(Utils.base64Decode("Zm9v"), utf8("foo")));
      assert(eqBytes(Utils.base64Decode("Zm9vYg"), utf8("foob")));
      assert(eqBytes(Utils.base64Decode("Zm9vYmE"), utf8("fooba")));
      assert(eqBytes(Utils.base64Decode("Zm9vYmFy"), utf8("foobar")));
    });
  });

  /// Binary edge payloads. Goldens = Node v26.5.0 Buffer.from(bytes).toString('base64'):
  /// 3x0x00 -> "AAAA", 5x0xFF -> "//////8=" (exercises '/' = 63 and single '='), and the
  /// full 0x00..0xFF 256-byte sweep (every alphabet char + '==' padding). All three
  /// re-verified with `node -e` on 2026-07-10 before pinning.
  suite("base64 binary edges (Node-derived)", func() {

    // 256-byte 0x00..0xFF sweep, base64 per Node Buffer (344 chars incl. '==').
    let SEQ_00_FF_B64 =
      "AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8gISIjJCUmJygpKissLS4vMDEyMzQ1Njc4OTo7PD0+P0BBQkNERUZHSElKS0xNTk9QUVJTVFVWV1hZWltcXV5fYGFiY2RlZmdoaWprbG1ub3BxcnN0dXZ3eHl6e3x9fn+AgYKDhIWGh4iJiouMjY6PkJGSk5SVlpeYmZqbnJ2en6ChoqOkpaanqKmqq6ytrq+wsbKztLW2t7i5uru8vb6/" #
      "wMHCw8TFxsfIycrLzM3Oz9DR0tPU1dbX2Nna29zd3t/g4eLj5OXm5+jp6uvs7e7v8PHy8/T19vf4+fr7/P3+/w==";

    test("3x0x00 encodes to AAAA and round-trips", func() {
      let bytes : [Nat8] = [0, 0, 0];
      assert(Utils.base64Encode(bytes) == "AAAA");
      assert(eqBytes(Utils.base64Decode("AAAA"), bytes));
    });

    test("5x0xFF encodes to //////8= and round-trips", func() {
      let bytes : [Nat8] = [255, 255, 255, 255, 255];
      assert(Utils.base64Encode(bytes) == "//////8=");
      assert(eqBytes(Utils.base64Decode("//////8="), bytes));
    });

    test("0x00..0xFF sweep matches Node byte-for-byte and round-trips", func() {
      let bytes = Array.tabulate<Nat8>(256, func(i : Nat) : Nat8 { Nat8.fromNat(i) });
      assert(Utils.base64Encode(bytes) == SEQ_00_FF_B64);
      assert(eqBytes(Utils.base64Decode(SEQ_00_FF_B64), bytes));
    });
  });

  /// Real use case: a representative x402 v2 payment header. The JSON mirrors the compact
  /// layout the canister itself builds (EvmSigner) and the client's btoa(JSON.stringify(...)).
  /// Golden = Node v26.5.0 Buffer.from(json,'utf8').toString('base64'), re-verified with
  /// `node -e` on 2026-07-10 (671-byte JSON -> 896-char base64). Pins that the canister's
  /// header encoding is byte-identical to what lenient upstream tooling produces/expects.
  suite("base64 x402 header payload", func() {

    let X402_JSON =
      "{\"x402Version\":2,\"accepted\":{\"scheme\":\"exact\",\"network\":\"eip155:84532\",\"amount\":\"1000\"," #
      "\"asset\":\"0x036CbD53842c5426634e7929541eC2318f3dCF7e\"," #
      "\"payTo\":\"0x1111111111111111111111111111111111111111\",\"maxTimeoutSeconds\":300," #
      "\"extra\":{\"name\":\"USDC\",\"version\":\"2\"}},\"payload\":{" #
      "\"signature\":\"0xdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef1b\"," #
      "\"authorization\":{\"from\":\"0x2222222222222222222222222222222222222222\"," #
      "\"to\":\"0x1111111111111111111111111111111111111111\",\"value\":\"1000\",\"validAfter\":\"0\"," #
      "\"validBefore\":\"1893456000\"," #
      "\"nonce\":\"0x00000000000000000000000000000000000000000000000000000017a3c1f000\"}}}";

    let X402_B64 =
      "eyJ4NDAyVmVyc2lvbiI6MiwiYWNjZXB0ZWQiOnsic2NoZW1lIjoiZXhhY3QiLCJuZXR3b3JrIjoiZWlwMTU1Ojg0NTMyIiwiYW1vdW50IjoiMTAwMCIsImFzc2V0IjoiMHgwMzZDYkQ1Mzg0MmM1NDI2NjM0ZTc5Mjk1NDFlQzIzMThmM2RDRjdlIiwicGF5VG8iOiIweDExMTExMTExMTExMTExMTExMTExMTExMTExMTExMTExMTExMTExMTEiLCJtYXhUaW1lb3V0U2Vjb25kcyI6MzAwLCJleHRyYSI6eyJuYW1lIjoiVVNEQyIsInZlcnNpb24iOiIyIn19LCJwYXlsb2FkIjp7InNpZ25hdHVyZSI6IjB4ZGVhZGJlZWZkZWFkYmVlZmRlYWRiZWVmZGVhZGJlZWZkZWFkYmVlZmRlYWRiZWVmZGVhZGJlZWZkZWFkYmVlZmRlYWRiZWVmZGVhZGJlZWZkZWFkYmVlZmRlYWRiZWVmZGVhZGJlZWZkZWFkYmVlZmRlYWRiZWVmZGVhZGJlZWYxYiIs" #
      "ImF1dGhvcml6YXRpb24iOnsiZnJvbSI6IjB4MjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMiIsInRvIjoiMHgxMTExMTExMTExMTExMTExMTExMTExMTExMTExMTExMTExMTExMTExIiwidmFsdWUiOiIxMDAwIiwidmFsaWRBZnRlciI6IjAiLCJ2YWxpZEJlZm9yZSI6IjE4OTM0NTYwMDAiLCJub25jZSI6IjB4MDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMTdhM2MxZjAwMCJ9fX0=";

    test("encode of the UTF-8 JSON equals Node's base64", func() {
      assert(Utils.base64Encode(utf8(X402_JSON)) == X402_B64);
    });

    test("decode round-trips to the exact JSON bytes", func() {
      assert(eqBytes(Utils.base64Decode(X402_B64), utf8(X402_JSON)));
    });
  });

  /// Strict-reject semantics of the 2026-07 rewritten decoder. Each case pins the
  /// parser-differential fix: where a lenient decoder (Node v26.5.0 Buffer 'base64',
  /// browsers, x402 facilitators) strips stray bytes and RE-ALIGNS the bit stream —
  /// so the same header could decode to different bytes upstream vs here — the strict
  /// decoder whole-input-rejects with []. Callers treat [] as invalid-header (fail-closed).
  suite("base64 strict-reject semantics", func() {

    test("invalid char anywhere rejects the whole input", func() {
      // "ab!cd": '!' is outside both alphabets. Node STRIPS it and decodes "abcd"
      // -> [0x69,0xb7,0x1d]; the old ic402 decoder truncated to [0x69]. Strict: [].
      assert(eqBytes(Utils.base64Decode("ab!cd"), []));
    });

    test("unpadded 2-char group is accepted", func() {
      // "QQ": unpadded final group. Node implies padding -> [0x41]; old ic402 dropped
      // the trailing chars entirely (-> []). Strict decoder now matches Node: [0x41].
      assert(eqBytes(Utils.base64Decode("QQ"), [0x41]));
    });

    test("padded 2-char group decodes identically", func() {
      // "QQ==": canonical padded form of the same byte. Both Node and ic402 -> [0x41].
      assert(eqBytes(Utils.base64Decode("QQ=="), [0x41]));
    });

    test("length % 4 == 1 after padding-strip rejects", func() {
      // "QQQQQ": a lone trailing char can never carry a whole byte (6 bits). Node
      // silently DROPS the orphan and returns 3 bytes [0x41,0x04,0x10]; strict: [].
      assert(eqBytes(Utils.base64Decode("QQQQQ"), []));
    });

    test("embedded space rejects", func() {
      // "Zm9v YmFy": Node strips whitespace and decodes "foobar"; the old ic402
      // decoder early-returned "foo". Whitespace is NOT part of the alphabet: [].
      assert(eqBytes(Utils.base64Decode("Zm9v YmFy"), []));
    });

    test("embedded newline rejects", func() {
      // "Zm9v\nYmFy": same as space — Node (and MIME-style decoders) strip \n and
      // decode "foobar"; strict decoder rejects the whole input: [].
      assert(eqBytes(Utils.base64Decode("Zm9v\nYmFy"), []));
    });

    test("base64url '-'/'_' accepted as 62/63, identical to '+'/'/'", func() {
      // "-_-_" vs "+/+/": Node's 'base64' decoder accepts BOTH alphabets and maps
      // '-'->62 / '_'->63; the old ic402 decoder rejected base64url (-> [] / truncation).
      // Strict decoder accepts both, byte-identically: [0xfb,0xff,0xbf].
      let urlSafe = Utils.base64Decode("-_-_");
      let standard = Utils.base64Decode("+/+/");
      assert(eqBytes(urlSafe, standard));
      assert(eqBytes(urlSafe, [0xfb, 0xff, 0xbf]));
    });

    test("three padding chars reject", func() {
      // "Q===": at most two trailing '=' are padding; the third lands mid-input and
      // '=' is not an alphabet char. Node returns [] here too (0 usable bytes). Strict: [].
      assert(eqBytes(Utils.base64Decode("Q==="), []));
    });

    test("lone '=' rejects", func() {
      // "=": padding with no data. After stripping, dataLen == 0 -> no bytes: [].
      assert(eqBytes(Utils.base64Decode("="), []));
    });

    test("empty input decodes to empty", func() {
      // "": vacuous input -> []. (Same as Node: zero bytes.)
      assert(eqBytes(Utils.base64Decode(""), []));
    });

    test("interior padding rejects", func() {
      // "QQ=Q": '=' is only valid as 1-2 TRAILING chars. Node tolerates it (decodes
      // [0x41], treating '=' as a terminator); interior '=' here is a malformed header
      // and the classic realignment vector, so strict decoder rejects: [].
      assert(eqBytes(Utils.base64Decode("QQ=Q"), []));
    });

    test("own padded encoder output always round-trips (len % 3 = 0, 1, 2)", func() {
      // The canister only ever emits padded standard-alphabet base64, so
      // base64Decode(base64Encode(bytes)) == bytes must hold for every tail shape.
      for (len in [24, 25, 26].vals()) {
        let bytes = Array.tabulate<Nat8>(len, func(i : Nat) : Nat8 { Nat8.fromNat((i * 37 + 11) % 256) });
        assert(eqBytes(Utils.base64Decode(Utils.base64Encode(bytes)), bytes));
      };
    });
  });
});
