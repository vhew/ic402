/// Unit tests for EvmSigner's derivation-path construction (2.15.0).
///
/// SCOPE. Only the construction/validation half is testable here. Deriving an address or
/// signing needs `ecdsa_public_key` / `sign_with_ecdsa`, which the `mops test` interpreter
/// cannot reach — the same limit `test/schnorrsigner.test.mo` documents for Schnorr. The
/// address and signature guarantees (different paths → different addresses; the
/// one-argument form ≡ the explicit `[]` form) are proven on a real replica in
/// `test/evmsigner-path.test.ts`.
///
/// What is locked in here: `EvmSignerAt` REFUSES an invalid path with `#err` instead of
/// trapping, and it refuses on exactly the bounds SchnorrSigner defines — the two signers
/// must never drift apart on what a valid path is, which is why the bound is reused rather
/// than restated.
import EvmSigner "../src/ic402/EvmSigner";
import SchnorrSigner "../src/ic402/SchnorrSigner";
import Blob "mo:base/Blob";
import Array "mo:base/Array";
import Nat8 "mo:base/Nat8";
import Text "mo:base/Text";
import { test; suite } "mo:test";

suite("EvmSignerAt path validation", func() {

  test("accepts the empty path — the 2.14.0 default", func() {
    let #ok(_) = EvmSigner.EvmSignerAt("dfx_test_key", []) else {
      assert false; return;
    };
  });

  test("accepts a labelled path", func() {
    let path = [
      Text.encodeUtf8("engramx"),
      Text.encodeUtf8("payments"),
      Text.encodeUtf8("secp256k1"),
      Text.encodeUtf8("1"),
    ];
    let #ok(_) = EvmSigner.EvmSignerAt("dfx_test_key", path) else {
      assert false; return;
    };
  });

  test("accepts a path at exactly the element limit", func() {
    let path = Array.tabulate<Blob>(
      SchnorrSigner.MAX_DERIVATION_PATH_ELEMENTS,
      func(_) { Blob.fromArray([0x01]) },
    );
    let #ok(_) = EvmSigner.EvmSignerAt("dfx_test_key", path) else {
      assert false; return;
    };
  });

  test("REFUSES one element over the limit — with #err, not a trap", func() {
    // The whole point of the factory: a class constructor cannot return a Result
    // (M0134), so an invalid path would otherwise have to trap. This library refuses.
    let path = Array.tabulate<Blob>(
      SchnorrSigner.MAX_DERIVATION_PATH_ELEMENTS + 1,
      func(_) { Blob.fromArray([0x01]) },
    );
    let #err(e) = EvmSigner.EvmSignerAt("dfx_test_key", path) else {
      assert false; return;
    };
    assert Text.contains(e, #text "too long");
  });

  test("REFUSES a path over the total byte budget", func() {
    let fat = Blob.fromArray(
      Array.tabulate<Nat8>(SchnorrSigner.MAX_DERIVATION_PATH_BYTES, func(_) { 0x02 })
    );
    let #err(e) = EvmSigner.EvmSignerAt("dfx_test_key", [fat, Blob.fromArray([0x03])]) else {
      assert false; return;
    };
    assert Text.contains(e, #text "too large");
  });

  test("the bound is SchnorrSigner's, not a private copy", func() {
    // If EvmSigner ever grows its own constants, this catches the drift: the element
    // count that Schnorr accepts must be exactly the count EvmSignerAt accepts, and the
    // first count Schnorr rejects must be the first EvmSignerAt rejects.
    let atLimit = Array.tabulate<Blob>(
      SchnorrSigner.MAX_DERIVATION_PATH_ELEMENTS,
      func(_) { Blob.fromArray([0x01]) },
    );
    let overLimit = Array.tabulate<Blob>(
      SchnorrSigner.MAX_DERIVATION_PATH_ELEMENTS + 1,
      func(_) { Blob.fromArray([0x01]) },
    );

    let schnorrAtLimit = switch (SchnorrSigner.validateDerivationPath(atLimit)) {
      case (#ok) { true }; case (#err(_)) { false };
    };
    let evmAtLimit = switch (EvmSigner.EvmSignerAt("k", atLimit)) {
      case (#ok(_)) { true }; case (#err(_)) { false };
    };
    let schnorrOver = switch (SchnorrSigner.validateDerivationPath(overLimit)) {
      case (#ok) { true }; case (#err(_)) { false };
    };
    let evmOver = switch (EvmSigner.EvmSignerAt("k", overLimit)) {
      case (#ok(_)) { true }; case (#err(_)) { false };
    };

    assert schnorrAtLimit == evmAtLimit;
    assert schnorrOver == evmOver;
    assert schnorrAtLimit and not schnorrOver;
  });
});
