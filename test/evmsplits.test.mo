/// 2.24.0: EvmSplits — the address of a 0xSplits push split (v2.2) paying a finder and a seller.
///
/// The vectors are EngramX's (ENGRAMX-INTENTS-SPEC A8), reproduced independently, and two of them
/// (the first and the last) were also returned by the deployed factory's
/// predictDeterministicAddress(params, owner 0, salt 0) on Base and on Base Sepolia (2026-11-25).
/// Each test names the mutation that turns it red.
import EvmSplits "../src/ic402/EvmSplits";
import EvmUtils "../src/ic402/EvmUtils";
import Text "mo:base/Text";
import { test; suite } "mo:test/async";

let A = "0x1111111111111111111111111111111111111111";
let B = "0x2222222222222222222222222222222222222222";
let C = "0x00112233445566778899aabbccddeeff00112233";
let D = "0xffeeddccbbaa99887766554433221100ffeeddcc";
let E = "0xabcdef0123456789abcdef0123456789abcdef01";
let F = "0x9f8e7d6c5b4a39281706fedcba9876543210fedc";
let USDC = "0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913";

func addr(finder : Text, seller : Text, share : Nat) : Text {
  switch (EvmSplits.splitAddress(EvmUtils.hexToBytes(finder), EvmUtils.hexToBytes(seller), share)) {
    case (?a) { EvmUtils.bytesToHex(a) };
    case (null) { "" };
  };
};

await suite("2.24.0: the split address", func() : async () {

  await test("matches the factory's deterministic address, finder first", func() : async () {
    // Mutation: any change to the encoding (word order, offsets, the owner or salt word, the
    // allocation split), the factory, the code hash or the slice of the final hash.
    assert addr(A, B, 1000) == "0x4ede36f2e215a06856612d4b98afa56c3afffa66"; // factory-confirmed
    assert addr(A, B, 500) == "0xdc4d347d48684e1b7807c317dd90b877a4c2725f";
    assert addr(A, B, 1) == "0xff6f9cc813d7f32ac7ffc449ca130c9c4f920950";
    assert addr(A, B, 9999) == "0xe5fa4028576b09be936e9b62b3439db0ce2be670";
    assert addr(C, D, 1000) == "0x1a902921edaec1c9d28449d3a6510bbaa580fc44";
    assert addr(C, D, 5000) == "0x739214b9a86b409aac3a37abf831ac3f316f3065";
    assert addr(E, F, 1337) == "0xce1e76df41975f0e58222d96816f08184cb9c314"; // factory-confirmed
  });

  await test("order matters: the seller-first split is another address", func() : async () {
    // Mutation: recipients swapped (seller first), which pays the finder the seller's share.
    assert addr(B, A, 9000) == "0xb4eb57dc248710f33ba0af3c47ee6f0df76aa6a6"; // [seller, finder], [9000, 1000]
    assert addr(B, A, 9000) != addr(A, B, 1000);
  });

  await test("no address for a malformed input: an address that is not 20 bytes, or a share past the whole", func() : async () {
    // Mutation: splitAddress drops its input checks (a 21-byte finder is encoded misaligned and can
    // collide with another pair; a share past 10000 traps).
    assert EvmSplits.splitAddress(EvmUtils.hexToBytes(A # "00"), EvmUtils.hexToBytes(B), 1000) == null;
    assert EvmSplits.splitAddress(EvmUtils.hexToBytes(A), EvmUtils.hexToBytes("0x22"), 1000) == null;
    assert EvmSplits.splitAddress(EvmUtils.hexToBytes(A), EvmUtils.hexToBytes(B), 10_001) == null;
  });
});

await suite("2.24.0: splitPayTo — which splits a canister accepts", func() : async () {

  let seller = B;

  await test("off until the operator sets a ceiling; then a share from 1 up to it", func() : async () {
    // Mutation: a null ceiling accepted, a share of 0 or above the ceiling accepted, or the
    // ceiling read as exclusive.
    assert EvmSplits.splitPayTo(8453, A, seller, 1000, USDC, null) == #err(EvmSplits.SPLITS_OFF);
    assert EvmSplits.splitPayTo(8453, A, seller, 1000, USDC, ?1000) == #ok("0x4ede36f2e215a06856612d4b98afa56c3afffa66");
    assert EvmSplits.splitPayTo(8453, A, seller, 1, USDC, ?1000) == #ok("0xff6f9cc813d7f32ac7ffc449ca130c9c4f920950");
    switch (EvmSplits.splitPayTo(8453, A, seller, 1001, USDC, ?1000)) { case (#err(e)) { assert Text.contains(e, #text "ceiling of 1000") }; case (_) { assert false } };
    switch (EvmSplits.splitPayTo(8453, A, seller, 0, USDC, ?1000)) { case (#err(_)) {}; case (_) { assert false } };
    // The seller always keeps a share, whatever ceiling a direct caller passes.
    switch (EvmSplits.splitPayTo(8453, A, seller, 10_000, USDC, ?10_000)) { case (#err(_)) {}; case (_) { assert false } };
    switch (EvmSplits.splitPayTo(8453, A, seller, 20_000, USDC, ?30_000)) { case (#err(_)) {}; case (_) { assert false } };
    assert EvmSplits.splitPayTo(8453, A, seller, 9999, USDC, ?30_000) == #ok("0xe5fa4028576b09be936e9b62b3439db0ce2be670");
  });

  await test("Base and Base Sepolia only; the same address on both", func() : async () {
    // Mutation: supportedChain accepts another chain, or drops one of the two.
    assert EvmSplits.splitPayTo(84532, A, seller, 1000, USDC, ?1000) == #ok("0x4ede36f2e215a06856612d4b98afa56c3afffa66");
    for (c in [0, 1, 10, 56, 100, 137, 324, 8452, 8454, 42161, 43114, 84531, 84533, 11155111].vals()) {
      switch (EvmSplits.splitPayTo(c, A, seller, 1000, USDC, ?1000)) { case (#err(_)) {}; case (_) { assert false } };
    };
  });

  await test("the finder is a real address, not zero, not the token; addresses compare in any case", func() : async () {
    // Mutation: a zero-address finder, the token as finder, or a malformed address accepted; the
    // address compared case-sensitively.
    let zero = "0x0000000000000000000000000000000000000000";
    switch (EvmSplits.splitPayTo(8453, zero, seller, 1000, USDC, ?1000)) { case (#err(e)) { assert Text.contains(e, #text "zero address") }; case (_) { assert false } };
    switch (EvmSplits.splitPayTo(8453, USDC, seller, 1000, Text.toLowercase(USDC), ?1000)) { case (#err(e)) { assert Text.contains(e, #text "paid token") }; case (_) { assert false } };
    switch (EvmSplits.splitPayTo(8453, "0x1234", seller, 1000, USDC, ?1000)) { case (#err(_)) {}; case (_) { assert false } };
    switch (EvmSplits.splitPayTo(8453, A, "not-an-address", 1000, USDC, ?1000)) { case (#err(_)) {}; case (_) { assert false } };
    // Mixed-case checksum forms give the same split.
    assert EvmSplits.splitPayTo(8453, "0x00112233445566778899AABBCCDDEEFF00112233", "0xFFEEDDCCBBAA99887766554433221100FFEEDDCC", 1000, USDC, ?1000) == #ok("0x1a902921edaec1c9d28449d3a6510bbaa580fc44");
  });
});
