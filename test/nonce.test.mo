/// Motoko unit tests for NonceManager.
import Nonce "../src/ic402/Nonce";
import Principal "mo:base/Principal";
import Time "mo:base/Time";
import { test; suite } "mo:test";

suite("NonceManager", func() {

  let testPrincipal = Principal.fromText("aaaaa-aa");

  test("generates unique nonces", func() {
    let mgr = Nonce.NonceManager(testPrincipal);
    let expiry = Time.now() + 300_000_000_000;

    let n1 = mgr.generate(expiry);
    let n2 = mgr.generate(expiry);
    let n3 = mgr.generate(expiry);

    assert(n1 != n2);
    assert(n2 != n3);
    assert(n1 != n3);
  });

  test("consume removes nonce", func() {
    let mgr = Nonce.NonceManager(testPrincipal);
    let expiry = Time.now() + 300_000_000_000;

    let nonce = mgr.generate(expiry);
    assert(mgr.exists(nonce));
    assert(mgr.consume(nonce));
    assert(not mgr.exists(nonce));
    // Double-consume fails
    assert(not mgr.consume(nonce));
  });

  test("rejects unknown nonce", func() {
    let mgr = Nonce.NonceManager(testPrincipal);
    assert(not mgr.consume("\00\01\02\03"));
  });

  test("toStable and loadStable roundtrip", func() {
    let mgr = Nonce.NonceManager(testPrincipal);
    let expiry = Time.now() + 300_000_000_000;

    let n1 = mgr.generate(expiry);
    let n2 = mgr.generate(expiry);
    let snapshot = mgr.toStable();

    let mgr2 = Nonce.NonceManager(testPrincipal);
    mgr2.loadStable(snapshot);

    assert(mgr2.exists(n1));
    assert(mgr2.exists(n2));
    assert(mgr2.consume(n1));
  });

  test("nonce is 32 bytes (SHA-256)", func() {
    let mgr = Nonce.NonceManager(testPrincipal);
    let nonce = mgr.generate(Time.now() + 300_000_000_000);
    assert(nonce.size() == 32);
  });
});
