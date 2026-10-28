// @testmode wasi
/// Conformance suite for ic402's secp256k1 signer recovery (EvmAddress.ecRecover), which every
/// EIP-3009 payment check rests on (Eip712.recoverAuthorizationSigner).
///
/// Every expectation comes from OUTSIDE ic402: Wycheproof's 252 secp256k1 ECDSA vectors, plus
/// one constructed vector cross-checked with @noble/curves. Provenance: test/fixtures/secp256k1/
/// README.md. Runs compiled (wasi): ~500 recoveries take ~40 s in the interpreter, ~2 s here.
///
/// HOW A VECTOR IS JUDGED. Wycheproof gives (public key, message, r || s) and asks "does this
/// verify?". ecRecover instead takes a digest, r, s and a recovery id v, and returns a key. ic402
/// "accepts" a vector when r and s are 32 bytes each (as Eip712.verifyAuthorization requires) and
/// ecRecover with v = 0 or v = 1 returns the vector's key. Trying both v is the generous reading:
/// a forgery that recovers the key under either v would be a forgery.
///
/// POLICY (where ic402 knowingly differs from a plain ECDSA verifier):
///   - High s is accepted. ecRecover normalizes s to n - s and flips the parity, so a signature
///     and its malleation recover the same key. Wycheproof's plain file treats high s as valid
///     too. (USDC rejects high s on chain; a payer who sends one gets #settlementFailed and no
///     value — see Gateway.mo.)
///   - Recovery ids 2 and 3 are not supported, exactly like Ethereum's ecrecover (v is 27/28).
///     When the nonce point R has x >= n, the signature's r is R.x - n; if x = r is ALSO on the
///     curve, ecRecover decompresses that point and returns a different key. Wycheproof tcId 115
///     and 247 are such signatures: valid ECDSA, refused by ic402 and by Ethereum alike. An
///     honest signer produces one about once in 2^128 signatures.
///   - The r + n FALLBACK, which Ethereum lacks: when x = r is NOT on the curve, ecRecover
///     retries with x = r + n. So ic402 recovers a signer for the policy vector below, where
///     Ethereum's ecrecover fails. Kept deliberately (2.18.x): building such a signature for a
///     chosen key needs a nonce with R.x >= n (~2^128 work), and if one ever arrived the on-chain
///     transfer would revert and the payer gets #settlementFailed, the same as any other reject.
import EvmAddress "../src/ic402/EvmAddress";
import EvmUtils "../src/ic402/EvmUtils";
import V "fixtures/secp256k1/Vectors";
import Blob "mo:base/Blob";
import Array "mo:base/Array";
import Debug "mo:base/Debug";
import { test; suite } "mo:test";

let secpN : Nat = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141;

// The two Wycheproof-valid signatures ic402 refuses by policy (recovery id 2/3; see above).
let refusedByPolicy : [Nat] = [115, 247];

type Outcome = { tcId : Nat; flags : [Text]; valid : Bool; accepted : Bool; parityMatches : Nat };

// Recover once per vector and parity (~500 recoveries), then let the tests inspect the results.
func judge(v : V.Wycheproof) : Outcome {
  let sig = Blob.toArray(v.sig);
  let pub = Blob.toArray(v.pub);
  var matches = 0;
  if (sig.size() == 64) {
    let h = Blob.toArray(v.hash);
    let r = Array.subArray(sig, 0, 32);
    let s = Array.subArray(sig, 32, 32);
    for (rec in ([0, 1] : [Nat8]).values()) {
      switch (EvmAddress.ecRecover(h, r, s, rec)) {
        case (?q) { if (q == pub) matches += 1 };
        case (null) {};
      };
    };
  };
  { tcId = v.tcId; flags = v.flags; valid = v.valid; accepted = matches > 0; parityMatches = matches };
};

let outcomes : [Outcome] = Array.map<V.Wycheproof, Outcome>(V.wycheproof, judge);

func contains(xs : [Nat], x : Nat) : Bool = Array.find<Nat>(xs, func(y) = y == x) != null;
func hasFlag(o : Outcome, flag : Text) : Bool = Array.find<Text>(o.flags, func(f) = f == flag) != null;

// What ic402 is expected to do with a vector: Wycheproof's verdict, except the policy refusals.
func expected(o : Outcome) : Bool = o.valid and not contains(refusedByPolicy, o.tcId);

suite("Wycheproof ecdsa_secp256k1_sha256_p1363_test.json — all 252", func() {
  test("the generator kept every vector (252: 167 valid, 85 invalid)", func() {
    assert outcomes.size() == 252;
    assert Array.filter<Outcome>(outcomes, func(o) = o.valid).size() == 167;
  });

  test("no invalid signature is accepted (85 vectors)", func() {
    var bad = 0;
    for (o in outcomes.values()) {
      if (not o.valid and o.accepted) {
        Debug.print("  FORGERY ACCEPTED: tcId " # debug_show(o.tcId) # " " # debug_show(o.flags));
        bad += 1;
      };
    };
    assert bad == 0;
  });

  // Per flag, so a failure names its category. A vector can carry several flags; it is counted
  // under each. The counts catch a generator that silently drops vectors.
  let expectedCounts : [(Text, Nat)] = [
    ("ValidSignature", 9), ("ArithmeticError", 106), ("SpecialCaseHash", 54),
    ("InvalidSignature", 49), ("EdgeCasePublicKey", 18), ("ModularInverse", 15),
    ("SmallRandS", 12), ("SignatureSize", 10), ("PointDuplication", 7), ("RangeCheck", 4),
    ("IntegerOverflow", 4), ("ModifiedInteger", 1), ("EdgeCaseShamirMultiplication", 1),
  ];
  for ((flag, count) in expectedCounts.values()) {
    test(flag # " (" # debug_show(count) # " vectors) match the expected result", func() {
      var seen = 0;
      var mismatches = 0;
      for (o in outcomes.values()) {
        if (hasFlag(o, flag)) {
          seen += 1;
          if (o.accepted != expected(o)) {
            Debug.print("  MISMATCH tcId " # debug_show(o.tcId) # " expected " # debug_show(expected(o)));
            mismatches += 1;
          };
        };
      };
      assert seen == count;
      assert mismatches == 0;
    });
  };

  test("the only Wycheproof-valid signatures refused are tcId 115 and 247 (recovery id 2/3)", func() {
    // Pins the policy both ways: if ecRecover learns recovery ids 2/3 (diverging from Ethereum's
    // ecrecover), or starts refusing anything else, this fails and the policy above needs a look.
    var refused : [Nat] = [];
    for (o in outcomes.values()) {
      if (o.valid and not o.accepted) refused := Array.append(refused, [o.tcId]);
    };
    assert refused == refusedByPolicy;
  });

  test("r or s of 0 or >= n returns null under both v (50 vectors), not merely a wrong key", func() {
    // The harness above only asks "is it the signer's key?", so dropping a range check (s == 0
    // in particular: Q = -z/r * G, a key nobody controls) would still pass it. This pins each
    // check directly. Counts: r = 0 in 7, r >= n in 31, s = 0 in 8, s >= n in 29.
    var seen = 0;
    var r0 = 0; var rn = 0; var s0 = 0; var sn = 0;
    for (v in V.wycheproof.values()) {
      let sig = Blob.toArray(v.sig);
      if (sig.size() == 64) {
        let rb = Array.subArray(sig, 0, 32);
        let sb = Array.subArray(sig, 32, 32);
        let r = EvmUtils.bytesToNat(rb);
        let s = EvmUtils.bytesToNat(sb);
        if (r == 0) r0 += 1;
        if (r >= secpN) rn += 1;
        if (s == 0) s0 += 1;
        if (s >= secpN) sn += 1;
        if (r == 0 or r >= secpN or s == 0 or s >= secpN) {
          seen += 1;
          let h = Blob.toArray(v.hash);
          assert EvmAddress.ecRecover(h, rb, sb, 0) == null;
          assert EvmAddress.ecRecover(h, rb, sb, 1) == null;
        };
      };
    };
    assert seen == 50;
    assert r0 == 7 and rn == 31 and s0 == 8 and sn == 29;
  });

  test("every accepted signature recovers the key under exactly one v", func() {
    // A wrong v must not recover the signer: it yields a different key (or none), which the
    // EIP-712 check then rejects as a signer mismatch.
    for (o in outcomes.values()) {
      if (o.accepted) assert o.parityMatches == 1;
    };
  });
});

suite("Policy: the r + n fallback (constructed; Ethereum's ecrecover cannot recover it)", func() {
  assert V.policy.size() == 1;
  let p = V.policy[0];
  let h = Blob.toArray(p.hash);
  let r = Blob.toArray(p.r);
  let s = Blob.toArray(p.s);

  test("ic402 recovers the signer: x = r is off the curve, so it retries x = r + n", func() {
    assert EvmAddress.ecRecover(h, r, s, p.v) == ?Blob.toArray(p.pub);
  });

  test("the other v recovers a different key", func() {
    let other : Nat8 = if (p.v == 0) 1 else 0;
    switch (EvmAddress.ecRecover(h, r, s, other)) {
      case (?q) { assert q != Blob.toArray(p.pub) };
      case (null) {};
    };
  });
});
