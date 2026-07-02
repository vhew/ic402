/// Unit tests for Gateway.verifyPayment EVM asset/domain resolution.
/// Regression guard for the bug where verifyPayment read the EIP-712 domain
/// (name/version) from chain.tokens[0] instead of the token matching the paid
/// `asset` — which on a multi-token chain made a valid signature fail to verify.
import Gateway "../src/ic402/Gateway";
import Types "../src/ic402/Types";
import Principal "mo:base/Principal";
import Blob "mo:base/Blob";
import Array "mo:base/Array";
import { test; suite } "mo:test";

suite("Gateway.verifyPayment", func() {

  let owner = Principal.fromText("aaaaa-aa");

  // A chain (Base Sepolia id) with TWO tokens carrying DIFFERENT EIP-712 domains.
  let token1 : Types.EvmTokenConfig = {
    address = "0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
    symbol = "AAA"; decimals = 6; name = ?"Token A"; version = ?"1";
  };
  let token2 : Types.EvmTokenConfig = {
    address = "0xbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";
    symbol = "BBB"; decimals = 6; name = ?"Token B"; version = ?"2";
  };
  let config : Types.Config = {
    recipient = { owner = owner; subaccount = null };
    tokens = [];
    evmChains = [{
      chainId = 84532;
      recipient = "0x1111111111111111111111111111111111111111";
      tokens = [token1, token2];
    }];
    evmRpcCanister = null;
    ecdsaKeyName = null;
    nonceExpirySeconds = null;
  };

  let payTo = "0x1111111111111111111111111111111111111111";
  let b32 = Blob.fromArray(Array.tabulate<Nat8>(32, func(_ : Nat) : Nat8 { 1 }));

  // A well-formed (but cryptographically bogus) EVM payment authorization that
  // passes every pre-crypto check in verifyPayment so the token lookup is reached.
  func sig() : Types.PaymentSignature = {
    scheme = "exact";
    network = "eip155:84532";
    signature = Blob.fromArray([]);
    publicKey = null;
    asset = null;
    sender = "0x2222222222222222222222222222222222222222";
    nonce = Blob.fromArray([]);
    authorization = ?{
      from = "0x2222222222222222222222222222222222222222";
      to = payTo;
      value = 5000;
      validAfter = 0;
      validBefore = 9_999_999_999;
      nonce = b32;
      v = 27;
      r = b32;
      s = b32;
    };
  };

  test("rejects an asset the canister does not configure (unsupported_asset)", func() {
    let gate = Gateway.Gateway(config, owner);
    let v = gate.verifyPayment(sig(), 5000, payTo, "0xcccccccccccccccccccccccccccccccccccccccc");
    assert(not v.isValid);
    assert(v.invalidReason == ?"unsupported_asset");
  });

  test("accepts a configured NON-FIRST token's asset (uses its own domain, not tokens[0])", func() {
    // token2 is the SECOND token; the old code resolved tokens[0]'s name/version.
    // With the fix the lookup recognizes token2 and proceeds to signature
    // verification (which fails on the dummy sig) rather than rejecting the asset.
    let gate = Gateway.Gateway(config, owner);
    let v = gate.verifyPayment(sig(), 5000, payTo, token2.address);
    assert(not v.isValid);
    assert(v.invalidReason == ?"invalid_exact_evm_payload_authorization_signature");
  });

  test("rejects an unconfigured chain (invalid_network)", func() {
    let gate = Gateway.Gateway(config, owner);
    let other : Types.PaymentSignature = { sig() with network = "eip155:99999" };
    let v = gate.verifyPayment(other, 5000, payTo, token1.address);
    assert(not v.isValid);
    assert(v.invalidReason == ?"invalid_network");
  });

  test("rejects a value that does not equal the expected amount (before the token lookup)", func() {
    let gate = Gateway.Gateway(config, owner);
    let v = gate.verifyPayment(sig(), 9999, payTo, token1.address);
    assert(not v.isValid);
    assert(v.invalidReason == ?"invalid_exact_evm_payload_authorization_value_mismatch");
  });
});

// ── SEC-1: global facilitator rate gate (pure token bucket) ──
suite("Gateway.tokenBucketStep", func() {
  let SEC : Int = 1_000_000_000;

  test("full bucket admits and decrements one token", func() {
    let r = Gateway.tokenBucketStep(10, 0, 0, 10, 2);
    assert(r.admit);
    assert(r.tokens == 9);
  });

  test("empty bucket with no elapsed time throttles", func() {
    let r = Gateway.tokenBucketStep(0, 0, 0, 10, 2);
    assert(not r.admit);
    assert(r.tokens == 0);
  });

  test("refills by whole-seconds * rate, capped at capacity", func() {
    let r = Gateway.tokenBucketStep(0, 0, 5 * SEC, 10, 2); // 5s * 2 = 10 refilled
    assert(r.admit);
    assert(r.tokens == 9);
    let big = Gateway.tokenBucketStep(0, 0, 100 * SEC, 10, 2); // would be 200; capped at 10
    assert(big.tokens == 9); // 10 refilled, 1 consumed — never unbounded
  });

  test("fractional second carries over (lastRefill advances by whole seconds only)", func() {
    let r = Gateway.tokenBucketStep(0, 0, 1_500_000_000, 10, 2); // 1.5s -> credit 1s (2 tokens)
    assert(r.admit);
    assert(r.tokens == 1);
    assert(r.lastRefill == SEC); // advanced by 1s, not 1.5s — the 0.5s is not lost
  });

  test("a burst depletes the bucket then throttles (no refill within the instant)", func() {
    let c1 = Gateway.tokenBucketStep(2, 0, 0, 2, 1);
    let c2 = Gateway.tokenBucketStep(c1.tokens, c1.lastRefill, 0, 2, 1);
    let c3 = Gateway.tokenBucketStep(c2.tokens, c2.lastRefill, 0, 2, 1);
    assert(c1.admit and c2.admit and not c3.admit);
  });
});

// ── Multi-token EIP-712 domain resolution (the pure core of the tokens[0] fix) ──
suite("Gateway.resolveEvmAsset / resolveEvmDomain", func() {
  let t1 : Types.EvmTokenConfig = {
    address = "0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
    symbol = "AAA"; decimals = 6; name = ?"Token A"; version = ?"1";
  };
  let t2 : Types.EvmTokenConfig = {
    address = "0xbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";
    symbol = "BBB"; decimals = 6; name = ?"Token B"; version = ?"2";
  };
  let chain : Types.EvmChainConfig = {
    chainId = 84532; recipient = "0x1111111111111111111111111111111111111111"; tokens = [t1, t2];
  };

  test("resolveEvmAsset: the payer-signed asset wins", func() {
    assert (Gateway.resolveEvmAsset(chain, ?t2.address) == t2.address);
  });
  test("resolveEvmAsset: null (legacy) falls back to the first configured token", func() {
    assert (Gateway.resolveEvmAsset(chain, null) == t1.address);
  });
  test("resolveEvmDomain: a NON-FIRST token uses its OWN domain, not tokens[0]", func() {
    switch (Gateway.resolveEvmDomain(chain, t2.address)) {
      case (?d) { assert (d.name == ?"Token B" and d.version == ?"2") };
      case (null) { assert false };
    };
  });
  test("resolveEvmDomain: the first token", func() {
    switch (Gateway.resolveEvmDomain(chain, t1.address)) {
      case (?d) { assert (d.name == ?"Token A" and d.version == ?"1") };
      case (null) { assert false };
    };
  });
  test("resolveEvmDomain: an unconfigured asset -> null", func() {
    switch (Gateway.resolveEvmDomain(chain, "0xcccccccccccccccccccccccccccccccccccccccc")) {
      case (null) {};
      case (?_) { assert false };
    };
  });
  test("resolveEvmDomain: address match is case-insensitive", func() {
    switch (Gateway.resolveEvmDomain(chain, "0xBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB")) {
      case (?d) { assert (d.name == ?"Token B") };
      case (null) { assert false };
    };
  });
});
