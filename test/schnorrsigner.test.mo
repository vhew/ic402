/// Unit tests for the SchnorrSigner pure helpers (module scope).
///
/// SCOPE — why there is no signing test here. `mops test` runs in the Motoko
/// interpreter, where the cost primitive is unimplemented: any call reaching
/// `Call.Cost.signWithSchnorr` dies with `execution error, Value.prim:
/// costSignWithSchnorr`. Compiling the suite to wasm instead does not help —
/// `mo:ic/Call` cannot even be TYPE-CHECKED under `-wasi-system-api`
/// (`M0086, async expressions are not supported`), so this file must NOT carry a
/// `// @testmode wasi` marker. Importing the module is fine; only calling the
/// primitive is not. Every signing and public-key path is therefore covered by the
/// replica-backed suite in `test/schnorr.test.ts`, never here.
///
/// What IS locked in here is the fail-closed input validation — the bounds that stop
/// an oversized argument TRAPPING the calling canister at `ic0.call_data_append`
/// (uncatchable), and the aux/algorithm pairing that decides which key a signature
/// verifies against.
import SchnorrSigner "../src/ic402/SchnorrSigner";
import Blob "mo:base/Blob";
import Array "mo:base/Array";
import Nat8 "mo:base/Nat8";
import Text "mo:base/Text";
import { test; suite } "mo:test";

suite("SchnorrSigner bounds", func() {

  // Every other bound test is written in terms of the constants, so it stays green even
  // if a constant is WRONG. These pin the literal values. 254 in particular is not the
  // spec's headline "at most 255": that figure is the whole extended-BIP32 path and the
  // IC prepends the calling canister's id, leaving 254 for the caller. A replica rejects
  // 255 with "The number of elements exceeds maximum allowed 254", so shipping 255 here
  // would put one value past fail-closed validation and into a wasted round trip.
  test("the literal bound values are pinned", func() {
    assert SchnorrSigner.MAX_DERIVATION_PATH_ELEMENTS == 254;
    assert SchnorrSigner.MAX_DERIVATION_PATH_BYTES == 8_192;
    assert SchnorrSigner.MAX_MESSAGE_BYTES == 1_048_576;
  });
});

suite("SchnorrSigner.validateMessage", func() {

  test("rejects an empty message", func() {
    // Not a platform rule — the replica has no check on the decoded `message` field,
    // so an empty message would likely be signed. We fail closed instead.
    let #err(e) = SchnorrSigner.validateMessage(Blob.fromArray([])) else {
      assert false; return;
    };
    assert Text.contains(e, #text "empty");
  });

  test("accepts a one-byte message", func() {
    let #ok = SchnorrSigner.validateMessage(Blob.fromArray([0x00])) else {
      assert false; return;
    };
  });

  test("accepts a message of exactly MAX_MESSAGE_BYTES", func() {
    let big = Blob.fromArray(Array.tabulate<Nat8>(SchnorrSigner.MAX_MESSAGE_BYTES, func(_) { 0x41 }));
    let #ok = SchnorrSigner.validateMessage(big) else { assert false; return };
  });

  test("rejects a message one byte over the cap", func() {
    let over = Blob.fromArray(Array.tabulate<Nat8>(SchnorrSigner.MAX_MESSAGE_BYTES + 1, func(_) { 0x41 }));
    let #err(e) = SchnorrSigner.validateMessage(over) else { assert false; return };
    assert Text.contains(e, #text "too large");
  });
});

suite("SchnorrSigner.validateDerivationPath", func() {

  test("accepts the empty path (the canister's own root key)", func() {
    let #ok = SchnorrSigner.validateDerivationPath([]) else { assert false; return };
  });

  test("accepts a path at exactly MAX_DERIVATION_PATH_ELEMENTS", func() {
    let path = Array.tabulate<Blob>(
      SchnorrSigner.MAX_DERIVATION_PATH_ELEMENTS,
      func(_) { Blob.fromArray([0x01]) },
    );
    let #ok = SchnorrSigner.validateDerivationPath(path) else { assert false; return };
  });

  test("rejects one element over the 255-element spec limit", func() {
    let path = Array.tabulate<Blob>(
      SchnorrSigner.MAX_DERIVATION_PATH_ELEMENTS + 1,
      func(_) { Blob.fromArray([0x01]) },
    );
    let #err(e) = SchnorrSigner.validateDerivationPath(path) else { assert false; return };
    assert Text.contains(e, #text "too long");
  });

  test("rejects a path whose elements exceed the total byte budget", func() {
    // Few elements, but far too many bytes — the element COUNT check alone would
    // let this through and the payload would still be unbounded.
    let fat = Blob.fromArray(Array.tabulate<Nat8>(SchnorrSigner.MAX_DERIVATION_PATH_BYTES, func(_) { 0x02 }));
    let #err(e) = SchnorrSigner.validateDerivationPath([fat, Blob.fromArray([0x03])]) else {
      assert false; return;
    };
    assert Text.contains(e, #text "too large");
  });
});

suite("SchnorrSigner.validateAux", func() {

  test("null aux is valid for both algorithms", func() {
    let #ok = SchnorrSigner.validateAux(#ed25519, null) else { assert false; return };
    let #ok = SchnorrSigner.validateAux(#bip340secp256k1, null) else { assert false; return };
  });

  test("bip341 with a 32-byte merkle root is valid for bip340secp256k1", func() {
    let root = Blob.fromArray(Array.tabulate<Nat8>(32, func(i) { Nat8.fromNat(i) }));
    let #ok = SchnorrSigner.validateAux(#bip340secp256k1, ?#bip341({ merkle_root_hash = root })) else {
      assert false; return;
    };
  });

  test("bip341 with an EMPTY merkle root is valid — key-path-only spend", func() {
    // Empty is the sanctioned encoding for "no script tree"; it is not a no-op, it
    // still tweaks the key.
    let #ok = SchnorrSigner.validateAux(
      #bip340secp256k1,
      ?#bip341({ merkle_root_hash = Blob.fromArray([]) }),
    ) else { assert false; return };
  });

  test("bip341 is REJECTED for ed25519", func() {
    // The taproot tweak is a secp256k1 construction; the spec allows the variant only
    // for bip340secp256k1.
    let root = Blob.fromArray(Array.tabulate<Nat8>(32, func(_) { 0x00 }));
    let #err(e) = SchnorrSigner.validateAux(#ed25519, ?#bip341({ merkle_root_hash = root })) else {
      assert false; return;
    };
    assert Text.contains(e, #text "ed25519");
  });

  test("rejects a merkle root that is neither empty nor 32 bytes", func() {
    // A wrong-length root silently changes which key the signature verifies against,
    // so this must never reach the replica.
    let short = Blob.fromArray(Array.tabulate<Nat8>(31, func(_) { 0xAA }));
    let #err(e) = SchnorrSigner.validateAux(#bip340secp256k1, ?#bip341({ merkle_root_hash = short })) else {
      assert false; return;
    };
    assert Text.contains(e, #text "32 bytes");
  });
});

suite("SchnorrSigner.xOnlyFromCompressed", func() {

  test("drops the parity byte of a 33-byte compressed key", func() {
    // BIP340 verification takes the 32-byte x-only key; schnorr_public_key returns
    // SEC1-compressed, so the leading 0x02/0x03 must come off.
    let compressed = Array.tabulate<Nat8>(33, func(i) { if (i == 0) { 0x02 } else { Nat8.fromNat(i) } });
    let #ok(x) = SchnorrSigner.xOnlyFromCompressed(compressed) else { assert false; return };
    assert x.size() == 32;
    assert x[0] == 1;
    assert x[31] == 32;
  });

  test("accepts the odd-parity prefix 0x03", func() {
    let compressed = Array.tabulate<Nat8>(33, func(i) { if (i == 0) { 0x03 } else { 0xFF } });
    let #ok(x) = SchnorrSigner.xOnlyFromCompressed(compressed) else { assert false; return };
    assert x.size() == 32;
  });

  test("rejects a 32-byte key — an ed25519 key passed by mistake", func() {
    let ed = Array.tabulate<Nat8>(32, func(_) { 0x01 });
    let #err(e) = SchnorrSigner.xOnlyFromCompressed(ed) else { assert false; return };
    assert Text.contains(e, #text "33-byte");
  });

  test("rejects an uncompressed 65-byte key", func() {
    let uncompressed = Array.tabulate<Nat8>(65, func(i) { if (i == 0) { 0x04 } else { 0x01 } });
    let #err(_) = SchnorrSigner.xOnlyFromCompressed(uncompressed) else { assert false; return };
  });

  test("rejects a 33-byte blob with a non-SEC1 leading byte", func() {
    let bogus = Array.tabulate<Nat8>(33, func(i) { if (i == 0) { 0x07 } else { 0x01 } });
    let #err(e) = SchnorrSigner.xOnlyFromCompressed(bogus) else { assert false; return };
    assert Text.contains(e, #text "compressed");
  });
});

suite("SchnorrSigner.cacheKey", func() {

  test("the same algorithm and path give the same key", func() {
    let p = [Blob.fromArray([0x01, 0x02])];
    assert SchnorrSigner.cacheKey(#ed25519, p) == SchnorrSigner.cacheKey(#ed25519, p);
  });

  test("the SAME path under different algorithms gives different keys", func() {
    // One key NAME serves both algorithms, so a cache keyed on the path alone would
    // hand back an Ed25519 key for a BIP340 request.
    let p = [Blob.fromArray([0x01])];
    assert SchnorrSigner.cacheKey(#ed25519, p) != SchnorrSigner.cacheKey(#bip340secp256k1, p);
  });

  test("different paths give different keys", func() {
    assert SchnorrSigner.cacheKey(#ed25519, [Blob.fromArray([0x01])])
        != SchnorrSigner.cacheKey(#ed25519, [Blob.fromArray([0x02])]);
  });

  test("element boundaries cannot collide", func() {
    // ["ab","cd"] and ["abcd"] concatenate identically. The `/` separator is what keeps
    // them apart — it is outside the fixed-width hex alphabet, so it is unambiguously an
    // element boundary. Two different paths must never share a cache slot: that would
    // hand back the key derived for one path in answer to a request for another.
    let split = [Blob.fromArray([0xAB]), Blob.fromArray([0xCD])];
    let joined = [Blob.fromArray([0xAB, 0xCD])];
    assert SchnorrSigner.cacheKey(#ed25519, split) != SchnorrSigner.cacheKey(#ed25519, joined);
  });

  test("the empty path differs from a path holding one empty element", func() {
    assert SchnorrSigner.cacheKey(#ed25519, [])
        != SchnorrSigner.cacheKey(#ed25519, [Blob.fromArray([])]);
  });
});
