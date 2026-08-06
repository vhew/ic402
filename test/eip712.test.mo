/// Motoko unit tests for Eip712 (EIP-712 typed data hashing).
import Eip712 "../src/ic402/Eip712";
import EvmUtils "../src/ic402/EvmUtils";
import Text "mo:base/Text";
import Array "mo:base/Array";
import Nat "mo:base/Nat";
import { test; suite } "mo:test";

suite("Eip712", func() {

  // ── Test vectors generated with viem/cast ──
  // USDC on Base Sepolia: 0x036CbD53842c5426634e7929541eC2318f3dCF7e, chainId=84532

  let baseSepUsdcAddr = EvmUtils.hexToBytes("0x036CbD53842c5426634e7929541eC2318f3dCF7e");
  let baseSepChainId : Nat = 84532;

  suite("transferWithAuthorizationTypeHash", func() {
    test("matches keccak256 of canonical string", func() {
      let th = Eip712.transferWithAuthorizationTypeHash();
      assert(th.size() == 32);
      assert(th[0] == 0x7c);
      assert(th[1] == 0x7c);
      assert(th[2] == 0x6c);
      assert(th[3] == 0xdb);
    });
  });

  suite("usdcDomainSeparator", func() {
    test("Base Sepolia matches viem output", func() {
      let ds = Eip712.usdcDomainSeparator(baseSepChainId, baseSepUsdcAddr);
      // Expected: 0x2f5ab5eec6c6d261a8ad2b303ae4ef05c8509de2250e072c3a2df0ad7f9f068b
      let expected = EvmUtils.hexToBytes("0x2f5ab5eec6c6d261a8ad2b303ae4ef05c8509de2250e072c3a2df0ad7f9f068b");
      assert(ds == expected);
    });
  });

  suite("hashTransferWithAuthorization", func() {
    test("known inputs produce expected struct hash", func() {
      let from = EvmUtils.hexToBytes("0xD2d6dC98E2fB707b74e0c3d453392a50a087790b");
      let to = EvmUtils.hexToBytes("0x167fa1c5fa0bc0bd005867f2a6df9cb4aac89e03");
      let value : Nat = 1000;
      let validAfter : Nat = 0;
      let validBefore : Nat = 1800000000;
      let nonce = EvmUtils.natToBytes(1, 32);

      let sh = Eip712.hashTransferWithAuthorization(from, to, value, validAfter, validBefore, nonce);
      // Expected: 0x3138e30595ca681b90a91c16dabad07f35b65dbbe64f5dc3f488dfe5b2e3a1be
      let expected = EvmUtils.hexToBytes("0x3138e30595ca681b90a91c16dabad07f35b65dbbe64f5dc3f488dfe5b2e3a1be");
      assert(sh == expected);
    });
  });

  suite("digest", func() {
    test("full EIP-712 digest matches viem output", func() {
      let domSep = EvmUtils.hexToBytes("0x2f5ab5eec6c6d261a8ad2b303ae4ef05c8509de2250e072c3a2df0ad7f9f068b");
      let structHash = EvmUtils.hexToBytes("0x3138e30595ca681b90a91c16dabad07f35b65dbbe64f5dc3f488dfe5b2e3a1be");

      let d = Eip712.digest(domSep, structHash);
      // Expected: 0x0ddbd8c5275ad4a8ae82da88329f4af26cedfa33eaf602d5d7f6021160cffd80
      let expected = EvmUtils.hexToBytes("0x0ddbd8c5275ad4a8ae82da88329f4af26cedfa33eaf602d5d7f6021160cffd80");
      assert(d == expected);
    });

    test("digest is 32 bytes", func() {
      let domSep = EvmUtils.natToBytes(0, 32);
      let structHash = EvmUtils.natToBytes(0, 32);
      let d = Eip712.digest(domSep, structHash);
      assert(d.size() == 32);
    });
  });

  suite("transferWithAuthorizationSelector", func() {
    test("matches 0xe3ee160e", func() {
      let sel = Eip712.transferWithAuthorizationSelector();
      assert(sel[0] == 0xe3);
      assert(sel[1] == 0xee);
      assert(sel[2] == 0x16);
      assert(sel[3] == 0x0e);
    });
  });

  suite("integration", func() {
    test("full flow: domain + struct + digest is deterministic", func() {
      let from = EvmUtils.hexToBytes("0xD2d6dC98E2fB707b74e0c3d453392a50a087790b");
      let to = EvmUtils.hexToBytes("0x167fa1c5fa0bc0bd005867f2a6df9cb4aac89e03");

      let domSep = Eip712.usdcDomainSeparator(baseSepChainId, baseSepUsdcAddr);
      let sh = Eip712.hashTransferWithAuthorization(from, to, 1000, 0, 1800000000, EvmUtils.natToBytes(1, 32));
      let d1 = Eip712.digest(domSep, sh);
      let d2 = Eip712.digest(domSep, sh);
      assert(d1 == d2);
    });

    test("different values produce different digests", func() {
      let from = EvmUtils.hexToBytes("0xD2d6dC98E2fB707b74e0c3d453392a50a087790b");
      let to = EvmUtils.hexToBytes("0x167fa1c5fa0bc0bd005867f2a6df9cb4aac89e03");
      let nonce = EvmUtils.natToBytes(1, 32);

      let domSep = Eip712.usdcDomainSeparator(baseSepChainId, baseSepUsdcAddr);
      let sh1 = Eip712.hashTransferWithAuthorization(from, to, 1000, 0, 1800000000, nonce);
      let sh2 = Eip712.hashTransferWithAuthorization(from, to, 2000, 0, 1800000000, nonce);
      assert(sh1 != sh2);

      let d1 = Eip712.digest(domSep, sh1);
      let d2 = Eip712.digest(domSep, sh2);
      assert(d1 != d2);
    });
  });

  suite("domainSeparator custom name", func() {
    test("USDC name matches on-chain DOMAIN_SEPARATOR for Base Sepolia", func() {
      let ds = Eip712.domainSeparator("USDC", "2", baseSepChainId, baseSepUsdcAddr);
      let expected = EvmUtils.hexToBytes("0x71f17a3b2ff373b803d70a5a07c046c1a2bc8e89c09ef722fcb047abe94c9818");
      assert(ds == expected);
    });
  });
});

// ═══════════════════════════════════════════════════════════════════════
// Field-driven encoding (2.13.0)
// ═══════════════════════════════════════════════════════════════════════
//
// GOLDEN VECTORS: every expected hash below was produced by viem 2.55.2 (hashStruct /
// hashTypedData / keccak256 — an independent, battle-tested EIP-712 implementation), per the
// 2.9.0 golden-vector methodology. The TransferWithAuthorization suite additionally pins the
// generic path against ic402's own mainnet-proven hardcoded constant — the strongest available
// anchor: if the generic encoder disagrees with it, the generic encoder is wrong.

suite("field-driven: TransferWithAuthorization self-consistency", func() {
  let twaFields : [(Text, Text)] = [
    ("from", "address"), ("to", "address"), ("value", "uint256"),
    ("validAfter", "uint256"), ("validBefore", "uint256"), ("nonce", "bytes32"),
  ];

  test("generic typeHash reproduces the hardcoded mainnet-proven constant", func() {
    switch (Eip712.typeHashOf("TransferWithAuthorization", twaFields)) {
      case (#ok(th)) { assert(th == Eip712.transferWithAuthorizationTypeHash()) };
      case (#err(_)) { assert(false) };
    };
  });

  test("generic hashStruct == hardcoded hashTransferWithAuthorization == viem", func() {
    let from = EvmUtils.hexToBytes("0x1111111111111111111111111111111111111111");
    let to = EvmUtils.hexToBytes("0x2222222222222222222222222222222222222222");
    let nonce = EvmUtils.hexToBytes("0x0303030303030303030303030303030303030303030303030303030303030303");
    let hardcoded = Eip712.hashTransferWithAuthorization(from, to, 5000, 0, 9999999999, nonce);
    let generic = Eip712.hashStructOf("TransferWithAuthorization", twaFields, [
      #address("0x1111111111111111111111111111111111111111"),
      #address("0x2222222222222222222222222222222222222222"),
      #uint(5000), #uint(0), #uint(9999999999),
      #fixedBytes(nonce),
    ]);
    switch (generic) {
      case (#ok(h)) {
        assert(h == hardcoded);
        assert(h == EvmUtils.hexToBytes("0x85a492be820cc3ae7a1eada2b5c2b97a8be6938190e5635253eb8789365b10c9")); // viem
      };
      case (#err(_)) { assert(false) };
    };
  });
});

suite("field-driven: viem golden vectors", func() {
  // Every atomic type in one struct: address, bool, string (unicode), dynamic bytes,
  // bytes1, bytes32, uint8 at its 255 boundary, uint256 wider than 64 bits.
  let orderFields : [(Text, Text)] = [
    ("maker", "address"), ("active", "bool"), ("memo", "string"), ("payload", "bytes"),
    ("tag", "bytes1"), ("salt", "bytes32"), ("tiny", "uint8"), ("amount", "uint256"),
  ];
  let orderValues : [Eip712.FieldValue] = [
    #address("0x2222222222222222222222222222222222222222"),
    #bool(true),
    #string("hello \u{2014} unicode \u{2713}"),
    #bytes([0xde, 0xad, 0xbe, 0xef]),
    #fixedBytes([0x7f]),
    #fixedBytes(EvmUtils.hexToBytes("0x0101010101010101010101010101010101010101010101010101010101010101")),
    #uint(255),
    #uint(123456789012345678901234567890),
  ];

  test("canonical type string", func() {
    switch (Eip712.encodeTypeString("Order", orderFields)) {
      case (#ok(s)) { assert(s == "Order(address maker,bool active,string memo,bytes payload,bytes1 tag,bytes32 salt,uint8 tiny,uint256 amount)") };
      case (#err(_)) { assert(false) };
    };
  });

  test("typeHash matches viem keccak256 of the canonical string", func() {
    switch (Eip712.typeHashOf("Order", orderFields)) {
      case (#ok(th)) { assert(th == EvmUtils.hexToBytes("0xd67576178f6d71bcd20abfa6ef057798e0ab5ea43b45220f6d5eadcfea3689b4")) };
      case (#err(_)) { assert(false) };
    };
  });

  test("hashStruct matches viem (pins pad directions, dynamic hashing, word order)", func() {
    switch (Eip712.hashStructOf("Order", orderFields, orderValues)) {
      case (#ok(h)) { assert(h == EvmUtils.hexToBytes("0x064d764aa5a50d392c4ad795f9a332c928a3f66efcd27aec668f863d80aa5f50")) };
      case (#err(_)) { assert(false) };
    };
  });

  test("empty string / empty bytes / false / zero match viem", func() {
    let r = Eip712.hashStructOf("Edge",
      [("a", "string"), ("b", "bytes"), ("c", "bool"), ("d", "uint64")],
      [#string(""), #bytes([]), #bool(false), #uint(0)]);
    switch (r) {
      case (#ok(h)) { assert(h == EvmUtils.hexToBytes("0x6d1138371b83c8d1e939148199f3f9bdd9f464e801dcec567b242e9477dabb07")) };
      case (#err(_)) { assert(false) };
    };
  });

  test("END-TO-END: domainSeparator + hashStructOf + digest match viem hashTypedData", func() {
    let contract = EvmUtils.hexToBytes("0x036CbD53842c5426634e7929541eC2318f3dCF7e");
    let ds = Eip712.domainSeparator("VenueX", "3", 8453, contract);
    switch (Eip712.hashStructOf("Order", orderFields, orderValues)) {
      case (#ok(sh)) {
        let d = Eip712.digest(ds, sh);
        assert(d == EvmUtils.hexToBytes("0x61bf954c0d601d6bd93359f778741bfeba5617f3b7a6db67be833de5586382ae"));
      };
      case (#err(_)) { assert(false) };
    };
  });
});

suite("field-driven: boundary rejections (fail-closed, never trap)", func() {
  func isErr(r : { #ok : [Nat8]; #err : Text }) : Bool {
    switch (r) { case (#err(_)) { true }; case (#ok(_)) { false } };
  };
  let addr = "0x1111111111111111111111111111111111111111";

  test("deliberately excluded types are rejected: int*, arrays, nested structs, bare uint", func() {
    assert(isErr(Eip712.typeHashOf("T", [("a", "int256")])));
    assert(isErr(Eip712.typeHashOf("T", [("a", "uint")])));
    assert(isErr(Eip712.typeHashOf("T", [("a", "address[]")])));
    assert(isErr(Eip712.typeHashOf("T", [("a", "uint256[3]")])));
    assert(isErr(Eip712.typeHashOf("T", [("a", "Person")])));
  });

  test("malformed widths are rejected: uint7/uint0/uint264/uint08, bytes0/bytes33/bytes08", func() {
    assert(isErr(Eip712.typeHashOf("T", [("a", "uint7")])));
    assert(isErr(Eip712.typeHashOf("T", [("a", "uint0")])));
    assert(isErr(Eip712.typeHashOf("T", [("a", "uint264")])));
    assert(isErr(Eip712.typeHashOf("T", [("a", "uint08")]))); // leading zero: two spellings must not alias
    assert(isErr(Eip712.typeHashOf("T", [("a", "bytes0")])));
    assert(isErr(Eip712.typeHashOf("T", [("a", "bytes33")])));
    assert(isErr(Eip712.typeHashOf("T", [("a", "bytes08")])));
  });

  test("SECURITY: identifier injection into the canonical type string is rejected", func() {
    // A field name carrying type-string syntax would alias a DIFFERENT struct than reviewed.
    assert(isErr(Eip712.typeHashOf("T", [("a,address evil)Other(", "uint256")])));
    assert(isErr(Eip712.typeHashOf("T(", [("a", "uint256")])));
    assert(isErr(Eip712.typeHashOf("T", [("", "uint256")])));
    assert(isErr(Eip712.typeHashOf("", [("a", "uint256")])));
    assert(isErr(Eip712.typeHashOf("T", [("1a", "uint256")]))); // digit-leading identifier
    assert(isErr(Eip712.typeHashOf("T", [("a b", "uint256")]))); // space
  });

  test("duplicate field names and empty field lists are rejected", func() {
    assert(isErr(Eip712.typeHashOf("T", [("a", "uint256"), ("a", "bool")])));
    assert(isErr(Eip712.typeHashOf("T", [])));
  });

  test("value/type conformance: range, length, tag mismatches all #err", func() {
    func hs(fields : [(Text, Text)], values : [Eip712.FieldValue]) : { #ok : [Nat8]; #err : Text } {
      Eip712.hashStructOf("T", fields, values);
    };
    assert(isErr(hs([("a", "uint8")], [#uint(256)]))); // out of range (255 is the max)
    assert(isErr(hs([("a", "bytes32")], [#fixedBytes([0x01])]))); // wrong length — no implicit pad
    assert(isErr(hs([("a", "bytes1")], [#fixedBytes([0x01, 0x02])])));
    assert(isErr(hs([("a", "address")], [#address("0x1234")]))); // short
    assert(isErr(hs([("a", "address")], [#address("1111111111111111111111111111111111111111")]))); // unprefixed
    assert(isErr(hs([("a", "address")], [#address("0xzz11111111111111111111111111111111111111")]))); // bad hex
    assert(isErr(hs([("a", "bytes32")], [#bytes([0x01])]))); // tag mismatch: fixed declared, dynamic supplied
    assert(isErr(hs([("a", "bytes")], [#fixedBytes([0x01])]))); // tag mismatch: dynamic declared, fixed supplied
    assert(isErr(hs([("a", "bool")], [#uint(1)]))); // no coercion
    assert(isErr(hs([("a", "uint256"), ("b", "bool")], [#uint(1)]))); // arity
    assert(isErr(hs([("a", "uint256")], [#uint(1), #bool(true)]))); // arity
  });

  test("uint8 boundary 255 is accepted; uint256 max is accepted", func() {
    switch (Eip712.hashStructOf("T", [("a", "uint8")], [#uint(255)])) {
      case (#ok(_)) {}; case (#err(_)) { assert(false) };
    };
    let max256 : Nat = 2 ** 256 - 1;
    switch (Eip712.hashStructOf("T", [("a", "uint256")], [#uint(max256)])) {
      case (#ok(_)) {}; case (#err(_)) { assert(false) };
    };
    assert(isErr(Eip712.hashStructOf("T", [("a", "uint256")], [#uint(max256 + 1)])));
    let _ = addr; // keep the shared fixture referenced
  });
});

suite("field-driven: review-round pins (namespace, cap, message truth, mutations)", func() {
  func isErr(r : { #ok : [Nat8]; #err : Text }) : Bool {
    switch (r) { case (#err(_)) { true }; case (#ok(_)) { false } };
  };
  func errContains(r : { #ok : [Nat8]; #err : Text }, needle : Text) : Bool {
    switch (r) { case (#err(m)) { Text.contains(m, #text needle) }; case (#ok(_)) { false } };
  };

  test("reserved struct name EIP712Domain is rejected (its hashStruct IS a domain separator)", func() {
    let domainFields : [(Text, Text)] = [
      ("name", "string"), ("version", "string"), ("chainId", "uint256"), ("verifyingContract", "address"),
    ];
    assert(errContains(Eip712.typeHashOf("EIP712Domain", domainFields), "reserved"));
  });

  test("atomic-shadowing struct names are rejected (viem InvalidStructTypeError parity)", func() {
    for (bad in ["address", "bool", "string", "uint256", "bytes32", "bytes", "uint", "int256", "intent", "uintX"].vals()) {
      assert(isErr(Eip712.typeHashOf(bad, [("a", "uint256")])));
    };
    // …but names merely CONTAINING those words (or capitalized) are fine.
    switch (Eip712.typeHashOf("Integration", [("a", "uint256")])) {
      case (#ok(_)) {}; case (#err(_)) { assert(false) };
    };
    switch (Eip712.typeHashOf("MyUint", [("a", "uint256")])) {
      case (#ok(_)) {}; case (#err(_)) { assert(false) };
    };
  });

  test("field-count cap: 64 accepted, 65 rejected with the cap named", func() {
    func mkFields(n : Nat) : [(Text, Text)] {
      Array.tabulate<(Text, Text)>(n, func(i : Nat) : (Text, Text) { ("f" # Nat.toText(i), "uint256") });
    };
    switch (Eip712.typeHashOf("Big", mkFields(64))) {
      case (#ok(_)) {}; case (#err(_)) { assert(false) };
    };
    assert(errContains(Eip712.typeHashOf("Big", mkFields(65)), "too many fields"));
  });

  test("array rejections tell the TRUTH for uint/bytes element types", func() {
    // Pre-fix, 'uint256[]' claimed "invalid uint width" — a false diagnosis (256 is valid;
    // the ARRAY is the exclusion) that would send an integrator retrying narrower widths.
    assert(errContains(Eip712.typeHashOf("T", [("a", "uint256[]")]), "DELIBERATELY unsupported"));
    assert(errContains(Eip712.typeHashOf("T", [("a", "bytes32[]")]), "DELIBERATELY unsupported"));
    assert(errContains(Eip712.typeHashOf("T", [("a", "uint256[3]")]), "DELIBERATELY unsupported"));
    // An int-prefixed IDENTIFIER used as a type is a nested-struct request, not a signed int.
    assert(errContains(Eip712.typeHashOf("T", [("a", "intent")]), "not a supported atomic type"));
    assert(errContains(Eip712.typeHashOf("T", [("a", "int256")]), "signed type"));
  });

  test("MUTATION PIN: non-multiple-of-8 uint widths are rejected (uint12, uint100)", func() {
    // Without these, dropping the `n % 8 == 0` clause passed the ENTIRE suite (viem hashes
    // 'uint12' without complaint, so golden vectors structurally cannot catch it).
    assert(isErr(Eip712.typeHashOf("T", [("a", "uint12")])));
    assert(isErr(Eip712.typeHashOf("T", [("a", "uint100")])));
  });

  test("MUTATION PIN: identifier acceptance covers digits and underscore; comma isolated", func() {
    // Without a positive digit/underscore vector, `i > 0` -> `i > 1` and `_` -> `,` mutations
    // of isIdentifier both survived the suite.
    switch (Eip712.encodeTypeString("Order_2", [("a1", "uint256"), ("_x", "bool")])) {
      case (#ok(s)) { assert(s == "Order_2(uint256 a1,bool _x)") };
      case (#err(_)) { assert(false) };
    };
    // The comma ALONE (no spaces/parens riding along) must be rejected.
    assert(isErr(Eip712.typeHashOf("T", [("a,b", "uint256")])));
  });
});

suite("field-driven: colon-namespaced struct names (2.13.1, venue convention)", func() {
  // GOLDEN VECTORS from viem 2.55.2 over the venue's REAL type — Hyperliquid's user-signed
  // withdraw (primaryType "HyperliquidTransaction:Withdraw", domain HyperliquidSignTransaction/
  // "1"/42161/zero address). The consumer that reported the refusal verified ethers v5/v6, viem,
  // alloy, and Turnkey all accept and hash the colon literally; 2.13.0's identifier rule was
  // stricter than the ecosystem it cited, and a name this encoder refuses is a digest no one
  // can produce through it.
  let hlFields : [(Text, Text)] = [
    ("hyperliquidChain", "string"), ("destination", "string"), ("amount", "string"), ("time", "uint64"),
  ];
  let hlValues : [Eip712.FieldValue] = [
    #string("Mainnet"),
    #string("0x2222222222222222222222222222222222222222"),
    #string("123.45"),
    #uint(1754300000000),
  ];

  test("the venue's real type round-trips WHOLE through encodeTypeString", func() {
    switch (Eip712.encodeTypeString("HyperliquidTransaction:Withdraw", hlFields)) {
      case (#ok(s)) { assert(s == "HyperliquidTransaction:Withdraw(string hyperliquidChain,string destination,string amount,uint64 time)") };
      case (#err(_)) { assert(false) };
    };
  });

  test("typeHash + hashStruct + FULL DIGEST match viem under the venue's real domain", func() {
    switch (Eip712.typeHashOf("HyperliquidTransaction:Withdraw", hlFields)) {
      case (#ok(th)) { assert(th == EvmUtils.hexToBytes("0xdbde952fa0de88158fc71336e44c61876611a2a65553bebd4d52b44a2a000d9a")) };
      case (#err(_)) { assert(false) };
    };
    switch (Eip712.hashStructOf("HyperliquidTransaction:Withdraw", hlFields, hlValues)) {
      case (#ok(sh)) {
        assert(sh == EvmUtils.hexToBytes("0x8dbb8dc11dc51644d73fca69eef464bbc59f13b5342ffa41390572ef97f6c248"));
        let ds = Eip712.domainSeparator("HyperliquidSignTransaction", "1", 42161, EvmUtils.hexToBytes("0x0000000000000000000000000000000000000000"));
        assert(Eip712.digest(ds, sh) == EvmUtils.hexToBytes("0x3c26236b8c2b1514bff511f1410bee0cf51735e6cde94cd995e4e502f2ab2ae7"));
      };
      case (#err(_)) { assert(false) };
    };
  });

  test("ANTI-NORMALIZATION PIN: the namespaced name never aliases its bare suffix", func() {
    // ':' is a scope separator in many policy DSLs — any matcher that splits on it would
    // silently alias HyperliquidTransaction:Withdraw to Withdraw. The two must commit to
    // DIFFERENT hashes, and the bare form is itself pinned to viem so a normalizing encoder
    // cannot sneak through by producing the suffix's (valid) hash.
    let ns = switch (Eip712.hashStructOf("HyperliquidTransaction:Withdraw", hlFields, hlValues)) {
      case (#ok(h)) { h }; case (#err(_)) { assert(false); [] };
    };
    let bare = switch (Eip712.hashStructOf("Withdraw", hlFields, hlValues)) {
      case (#ok(h)) { h }; case (#err(_)) { assert(false); [] };
    };
    assert(ns != bare);
    assert(bare == EvmUtils.hexToBytes("0xaf72848c0697f192e893325116981750acf737bf78e15ac617b5b05e05ab8376")); // viem
  });

  test("colon boundaries stay closed: empty segments, multi-colon, colon in FIELD names", func() {
    func isErr(r : { #ok : [Nat8]; #err : Text }) : Bool {
      switch (r) { case (#err(_)) { true }; case (#ok(_)) { false } };
    };
    assert(isErr(Eip712.typeHashOf(":Withdraw", [("a", "uint256")])));
    assert(isErr(Eip712.typeHashOf("Foo:", [("a", "uint256")])));
    assert(isErr(Eip712.typeHashOf("Foo::Bar", [("a", "uint256")])));
    assert(isErr(Eip712.typeHashOf("A:B:C", [("a", "uint256")])));
    assert(isErr(Eip712.typeHashOf(":", [("a", "uint256")])));
    // Field names carry no namespacing anywhere in the ecosystem — strict rule unchanged.
    assert(isErr(Eip712.typeHashOf("T", [("a:b", "uint256")])));
    // Reserved rule unchanged; a FIRST SEGMENT of EIP712Domain is also refused — viem injects
    // an EIP712Domain entry into every types map and truncates the primaryType at the colon
    // for dependency lookup, so "EIP712Domain:X" diverges between viem and ethers PERMANENTLY
    // (empirically verified against viem 2.55.2).
    assert(isErr(Eip712.typeHashOf("EIP712Domain", [("a", "uint256")])));
    assert(isErr(Eip712.typeHashOf("EIP712Domain:X", [("a", "uint256")])));
  });

  test("SECURITY: structural characters inside a colon SEGMENT are rejected — both segments", func() {
    func isErr(r : { #ok : [Nat8]; #err : Text }) : Bool {
      switch (r) { case (#err(_)) { true }; case (#ok(_)) { false } };
    };
    // Review-found gap: every earlier rejection failed on emptiness/count/shadow, so a mutant
    // of isStructName that only checked segments non-empty passed the whole suite while
    // accepting these — which alias NESTED struct definitions under the canonical grammar
    // (e.g. ethers reads "Order:Safe(Evil e)Evil(address owner)" as Order:Safe{Evil e} +
    // Evil{address owner}): a valid signature over an unreviewed struct.
    assert(isErr(Eip712.typeHashOf("Order:Safe(Evil e)Evil", [("owner", "address")]))); // 2nd segment
    assert(isErr(Eip712.typeHashOf("Evil(uint256 a)X:Withdraw", [("a", "uint256")]))); // 1st segment
    assert(isErr(Eip712.typeHashOf("A:B c", [("a", "uint256")]))); // space
    assert(isErr(Eip712.typeHashOf("A:B,C", [("a", "uint256")]))); // comma
    assert(isErr(Eip712.typeHashOf("A:B)C(", [("a", "uint256")]))); // parens
    assert(isErr(Eip712.typeHashOf("Foo:2Bar", [("a", "uint256")]))); // digit-leading 2nd segment
  });

  test("colon names are EXEMPT from the atomic-shadow prefix rule (viem/ethers verify them)", func() {
    // Review round 2: the prefix arm ran against the FULL name, refusing "intents:Swap" with
    // an error claiming standard tooling rejects it — disproved on the full wallet path
    // (viem 2.55.2 + ethers 6.17.0 sign AND verify these with singleton types maps). No
    // solidity atomic contains a colon, and these names can only ever be the primaryType
    // here, so nothing can shadow.
    switch (Eip712.typeHashOf("intents:Swap", [("a", "uint256")])) {
      case (#ok(_)) {}; case (#err(_)) { assert(false) };
    };
    switch (Eip712.typeHashOf("uint256:Foo", [("a", "uint256")])) {
      case (#ok(_)) {}; case (#err(_)) { assert(false) };
    };
    // Bare atomic-family names stay refused (that rule is unchanged for non-colon names).
    func isErr(r : { #ok : [Nat8]; #err : Text }) : Bool {
      switch (r) { case (#err(_)) { true }; case (#ok(_)) { false } };
    };
    assert(isErr(Eip712.typeHashOf("intents", [("a", "uint256")])));
    assert(isErr(Eip712.typeHashOf("uint256", [("a", "uint256")])));
  });

  test("MUTATION PIN: digits/underscores accepted in BOTH segments (positive round-trip)", func() {
    switch (Eip712.encodeTypeString("Venue_2:Order_1", [("a", "uint256")])) {
      case (#ok(s)) { assert(s == "Venue_2:Order_1(uint256 a)") };
      case (#err(_)) { assert(false) };
    };
  });
});
