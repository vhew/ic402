/// Unit tests for the 2.16.0 `…At` construction forms (module scope).
///
/// SCOPE. Only construction and validation are testable here — deriving a key needs
/// `ecdsa_public_key`, unreachable from the `mops test` interpreter (the limit
/// `test/schnorrsigner.test.mo` documents). The address guarantees are proven on a replica
/// in `test/derivation-paths.test.ts`.
///
/// What is locked in: every `…At` form refuses an invalid path with `#err` rather than
/// trapping, and all of them refuse at EXACTLY the bound `SchnorrSigner` defines. The bound
/// is reused, never restated; if any site grows a private copy, the drift tests below fail.
import EvmSigner "../src/ic402/EvmSigner";
import EvmSender "../src/ic402/EvmSender";
import SchnorrSigner "../src/ic402/SchnorrSigner";
import Utils "../src/ic402/Utils";
import Blob "mo:base/Blob";
import Array "mo:base/Array";
import Nat8 "mo:base/Nat8";
import Text "mo:base/Text";
import { test; suite } "mo:test";

// A labelled path of the shape downstream uses: ["engramx", <purpose>, <curve>, <version>].
let LABELLED : [Blob] = [
  Text.encodeUtf8("engramx"),
  Text.encodeUtf8("payments"),
  Text.encodeUtf8("secp256k1"),
  Text.encodeUtf8("1"),
];

func overLimitByCount() : [Blob] {
  Array.tabulate<Blob>(
    SchnorrSigner.MAX_DERIVATION_PATH_ELEMENTS + 1,
    func(_) { Blob.fromArray([0x01]) },
  );
};

func overLimitByBytes() : [Blob] {
  let fat = Blob.fromArray(
    Array.tabulate<Nat8>(SchnorrSigner.MAX_DERIVATION_PATH_BYTES, func(_) { 0x02 })
  );
  [fat, Blob.fromArray([0x03])];
};

suite("EvmSenderAt path validation", func() {

  test("accepts the empty path — the pre-2.16.0 default", func() {
    let #ok(_) = EvmSender.EvmSenderAt("dfx_test_key", null, []) else {
      assert false; return;
    };
  });

  test("accepts a labelled path", func() {
    let #ok(_) = EvmSender.EvmSenderAt("dfx_test_key", null, LABELLED) else {
      assert false; return;
    };
  });

  test("REFUSES an over-count path with #err, not a trap", func() {
    let #err(e) = EvmSender.EvmSenderAt("dfx_test_key", null, overLimitByCount()) else {
      assert false; return;
    };
    assert Text.contains(e, #text "too long");
  });

  test("REFUSES an over-bytes path with #err", func() {
    let #err(e) = EvmSender.EvmSenderAt("dfx_test_key", null, overLimitByBytes()) else {
      assert false; return;
    };
    assert Text.contains(e, #text "too large");
  });
});

suite("every …At form shares SchnorrSigner's bound", func() {

  // If any site grows its own constants, its accept/refuse boundary stops matching
  // SchnorrSigner's and this fails. That is the whole point of reusing the function.
  let atLimit = Array.tabulate<Blob>(
    SchnorrSigner.MAX_DERIVATION_PATH_ELEMENTS,
    func(_) { Blob.fromArray([0x01]) },
  );
  let overLimit = overLimitByCount();

  func schnorrAccepts(p : [Blob]) : Bool {
    switch (SchnorrSigner.validateDerivationPath(p)) {
      case (#ok) { true }; case (#err(_)) { false };
    };
  };
  func signerAccepts(p : [Blob]) : Bool {
    switch (EvmSigner.EvmSignerAt("k", p)) { case (#ok(_)) { true }; case (#err(_)) { false } };
  };
  func senderAccepts(p : [Blob]) : Bool {
    switch (EvmSender.EvmSenderAt("k", null, p)) {
      case (#ok(_)) { true }; case (#err(_)) { false };
    };
  };

  test("EvmSignerAt's boundary is SchnorrSigner's", func() {
    assert signerAccepts(atLimit) == schnorrAccepts(atLimit);
    assert signerAccepts(overLimit) == schnorrAccepts(overLimit);
  });

  test("EvmSenderAt's boundary is SchnorrSigner's", func() {
    assert senderAccepts(atLimit) == schnorrAccepts(atLimit);
    assert senderAccepts(overLimit) == schnorrAccepts(overLimit);
  });

  test("and that boundary actually discriminates", func() {
    // Guards against all three agreeing because all three always say yes.
    assert schnorrAccepts(atLimit);
    assert not schnorrAccepts(overLimit);
  });
});

suite("Utils.derivationCacheKey", func() {

  // Identity's public-key cache is keyed with this. Before 2.16.0 it was a single unkeyed
  // `var`, so getPublicKey(keyNameA) then getPublicKey(keyNameB) returned A's key; adding a
  // path would have widened that confusion to paths. These pin the properties that stop it.

  test("different paths under one prefix give different keys", func() {
    assert Utils.derivationCacheKey("key_1", [Blob.fromArray([0x01])])
        != Utils.derivationCacheKey("key_1", [Blob.fromArray([0x02])]);
  });

  test("different prefixes under one path give different keys", func() {
    // The old bug: two key NAMES sharing a cache slot.
    assert Utils.derivationCacheKey("key_1", LABELLED)
        != Utils.derivationCacheKey("dfx_test_key", LABELLED);
  });

  test("the same prefix and path are stable", func() {
    assert Utils.derivationCacheKey("key_1", LABELLED)
        == Utils.derivationCacheKey("key_1", LABELLED);
  });

  test("element boundaries cannot collide", func() {
    // ["ab","cd"] and ["abcd"] concatenate identically; the `/` separator is what keeps them
    // apart, being outside the fixed-width hex alphabet. Remove it and a cache would hand
    // back the key derived for one path in answer to a request for another.
    assert Utils.derivationCacheKey("k", [Blob.fromArray([0xAB]), Blob.fromArray([0xCD])])
        != Utils.derivationCacheKey("k", [Blob.fromArray([0xAB, 0xCD])]);
  });

  test("the empty path differs from one empty element", func() {
    assert Utils.derivationCacheKey("k", [])
        != Utils.derivationCacheKey("k", [Blob.fromArray([])]);
  });

  test("a prefix cannot bleed into the path encoding", func() {
    // prefix "a" + path ["b"] must not equal prefix "a/62" + empty path.
    assert Utils.derivationCacheKey("a", [Blob.fromArray([0x62])])
        != Utils.derivationCacheKey("a/62", []);
  });
});
