// @testmode wasi
/// Conformance suite for ic402's secp256k1 signer recovery, EvmAddress.ecRecover. Two callers
/// rest on it: Eip712.recoverAuthorizationSigner (every EIP-3009 payment check) and
/// ServiceRegistry.recoverBuyerActionSigner (EVM buyer confirm/dispute, final with no on-chain
/// step behind it).
///
/// Every expectation comes from OUTSIDE ic402: Wycheproof's 252 secp256k1 ECDSA vectors, with
/// each verifying signature's recovery id found by plain ECDSA verification in the generator,
/// plus two constructed vectors cross-checked with @noble/curves. Provenance:
/// test/fixtures/secp256k1/README.md. Runs compiled (wasi): ~500 recoveries take ~40 s in the
/// interpreter, ~2 s here.
///
/// HOW A VECTOR IS JUDGED. Wycheproof gives (public key, message, r || s) and asks "does this
/// verify?". ecRecover instead takes a digest, r, s and a recovery id v, and returns a key. ic402
/// "accepts" a vector when r and s are 32 bytes each (as Eip712.verifyAuthorization requires) and
/// ecRecover with v = 0 or v = 1 returns the vector's key. Trying both v is the generous reading:
/// a forgery that recovers the key under either v would be a forgery. Which v does it is pinned
/// separately, against the generator's recovery id.
///
/// POLICY (where ic402 knowingly differs from a plain ECDSA verifier or Ethereum's ecrecover):
///   - High s is accepted. ecRecover normalizes s to n - s and flips the parity, so a signature
///     and its malleation recover the same key. Wycheproof's plain file treats high s as valid
///     too; USDC rejects it on chain.
///   - v is read only as a parity bit. ic402 never derives R.x = r + n from v, so like Ethereum
///     (v = 27/28) it cannot recover signatures that need recovery id 2 or 3: when the nonce
///     point R has x >= n and x = r is ALSO on the curve, ecRecover returns a different key.
///     Wycheproof tcId 115 and 247 are such signatures. An honest signer produces one about once
///     in 2^128 signatures. (Other v values are folded onto a parity, not refused.)
///   - The r + n FALLBACK, which Ethereum lacks: when x = r is NOT on the curve, ecRecover
///     retries with x = r + n (if that is below p), and recovers a signer Ethereum cannot.
///   - The parity FALLTHROUGH, which Ethereum lacks: when the given v's point yields the point
///     at infinity, ecRecover tries the other parity, so both v return the same key where
///     Ethereum's ecrecover fails for one of them.
///   The last two are kept deliberately (2.18.x) and pinned below. Neither is a forgery path:
///   the key either one recovers is one the signature genuinely verifies under, and steering it
///   onto a chosen address means solving a discrete log. For a payment, the on-chain transfer
///   with such a signature reverts, and settle returns #settlementFailed with no value moved.
///   POST /verify (Gateway.verifyPayment) checks only the recovery, so it reports isValid for
///   such a signature, and for a high-s one. Do not deliver on /verify alone.
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

type Outcome = {
  tcId : Nat;
  flags : [Text];
  valid : Bool;
  recId : ?Nat8;
  byV0 : Bool; // ecRecover(.., 0) returned the vector's key
  byV1 : Bool;
  accepted : Bool;
};

// Recover once per vector and parity (~500 recoveries), then let the tests inspect the results.
func judge(v : V.Wycheproof) : Outcome {
  let sig = Blob.toArray(v.sig);
  let pub = Blob.toArray(v.pub);
  var byV0 = false;
  var byV1 = false;
  if (sig.size() == 64) {
    let h = Blob.toArray(v.hash);
    let r = Array.subArray(sig, 0, 32);
    let s = Array.subArray(sig, 32, 32);
    byV0 := EvmAddress.ecRecover(h, r, s, 0) == ?pub;
    byV1 := EvmAddress.ecRecover(h, r, s, 1) == ?pub;
  };
  { tcId = v.tcId; flags = v.flags; valid = v.valid; recId = v.recId; byV0; byV1; accepted = byV0 or byV1 };
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

  test("the only Wycheproof-valid signatures refused are tcId 115 and 247, recovery id 3 and 2", func() {
    // Pins the policy both ways: if ecRecover learns recovery ids 2/3 (diverging from Ethereum's
    // ecrecover), or starts refusing anything else, this fails and the policy above needs a look.
    var refused : [Nat] = [];
    for (o in outcomes.values()) {
      if (o.valid and not o.accepted) {
        refused := Array.append(refused, [o.tcId]);
        assert o.recId == ?2 or o.recId == ?3;
      };
    };
    assert refused == refusedByPolicy;
  });

  test("each accepted signature recovers its key under its own recovery id only (165 vectors)", func() {
    // The id comes from the generator's plain ECDSA verification, not from ic402. This pins the
    // v -> parity mapping and, through Wycheproof's high-s vectors, the parity flip that goes
    // with normalizing s. For these vectors the other v recovers a different key (or none).
    var checked = 0;
    for (o in outcomes.values()) {
      if (o.accepted) {
        checked += 1;
        switch (o.recId) {
          case (?0) { assert o.byV0 and not o.byV1 };
          case (?1) { assert o.byV1 and not o.byV0 };
          case (_) {
            Debug.print("  tcId " # debug_show(o.tcId) # " accepted with recId " # debug_show(o.recId));
            assert false;
          };
        };
      };
    };
    assert checked == 165;
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

  test("x = r off the curve with r + n >= p returns null under both v (tcId 33, 35, 204)", func() {
    // Pins the `r + n < p` bound on the fallback. Without it, x = r + n would be reduced mod p,
    // and for these three that is a valid x-coordinate, so a (wrong) key would come back.
    for (id in [33, 35, 204].values()) {
      let ?v = Array.find<V.Wycheproof>(V.wycheproof, func(w) = w.tcId == id) else {
        assert false;
        return;
      };
      let sig = Blob.toArray(v.sig);
      assert sig.size() == 64;
      let h = Blob.toArray(v.hash);
      let r = Array.subArray(sig, 0, 32);
      let s = Array.subArray(sig, 32, 32);
      assert EvmUtils.bytesToNat(r) + secpN >= 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEFFFFFC2F;
      assert EvmAddress.ecRecover(h, r, s, 0) == null;
      assert EvmAddress.ecRecover(h, r, s, 1) == null;
    };
  });
});

suite("Policy vectors (constructed; Ethereum's ecrecover disagrees on each)", func() {
  assert V.policy.size() == 2;
  for (p in V.policy.values()) {
    let h = Blob.toArray(p.hash);
    let r = Blob.toArray(p.r);
    let s = Blob.toArray(p.s);
    let want = func(k : ?Blob) : ?[Nat8] = switch (k) {
      case (?b) { ?Blob.toArray(b) };
      case (null) { null };
    };
    test(p.name # ": v = 0 recovers what policy.json records", func() {
      assert EvmAddress.ecRecover(h, r, s, 0) == want(p.v0);
    });
    test(p.name # ": v = 1 recovers what policy.json records", func() {
      assert EvmAddress.ecRecover(h, r, s, 1) == want(p.v1);
    });
    test(p.name # ": the signer is recovered under some v", func() {
      assert want(p.v0) == ?Blob.toArray(p.signer) or want(p.v1) == ?Blob.toArray(p.signer);
    });
  };
});
