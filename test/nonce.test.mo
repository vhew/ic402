/// Motoko unit tests for NonceManager.
import Nonce "../src/ic402/Nonce";
import Principal "mo:base/Principal";
import Time "mo:base/Time";
import { test; suite } "mo:test";

suite("NonceManager", func() {

  let testPrincipal = Principal.fromText("aaaaa-aa");
  let testAmount : Nat = 1_000;

  test("generates unique nonces", func() {
    let mgr = Nonce.NonceManager(testPrincipal);
    let expiry = Time.now() + 300_000_000_000;

    let n1 = mgr.generate(expiry, testAmount);
    let n2 = mgr.generate(expiry, testAmount);
    let n3 = mgr.generate(expiry, testAmount);

    assert(n1 != n2);
    assert(n2 != n3);
    assert(n1 != n3);
  });

  test("lock returns bound amount, consumeLocked removes nonce", func() {
    let mgr = Nonce.NonceManager(testPrincipal);
    let expiry = Time.now() + 300_000_000_000;

    let nonce = mgr.generate(expiry, testAmount);
    assert(mgr.exists(nonce));

    // Lock returns the bound amount
    switch (mgr.lock(nonce)) {
      case (?amount) { assert(amount == testAmount) };
      case (null) { assert(false) };
    };

    // Double-lock fails (already locked)
    assert(mgr.lock(nonce) == null);

    // Consume permanently removes the nonce
    mgr.consumeLocked(nonce);
    assert(not mgr.exists(nonce));

    // Lock after consume fails (nonce gone)
    assert(mgr.lock(nonce) == null);
  });

  test("unlock allows retry", func() {
    let mgr = Nonce.NonceManager(testPrincipal);
    let expiry = Time.now() + 300_000_000_000;

    let nonce = mgr.generate(expiry, testAmount);

    // Lock it
    switch (mgr.lock(nonce)) {
      case (?amount) { assert(amount == testAmount) };
      case (null) { assert(false) };
    };

    // Unlock allows re-locking
    mgr.unlock(nonce);
    switch (mgr.lock(nonce)) {
      case (?amount) { assert(amount == testAmount) };
      case (null) { assert(false) };
    };
  });

  test("rejects unknown nonce", func() {
    let mgr = Nonce.NonceManager(testPrincipal);
    assert(mgr.lock("\00\01\02\03") == null);
  });

  test("binds amount correctly", func() {
    let mgr = Nonce.NonceManager(testPrincipal);
    let expiry = Time.now() + 300_000_000_000;

    let n1 = mgr.generate(expiry, 500);
    let n2 = mgr.generate(expiry, 5_000);

    switch (mgr.lock(n1)) {
      case (?a) { assert(a == 500) };
      case (null) { assert(false) };
    };
    mgr.unlock(n1);

    switch (mgr.lock(n2)) {
      case (?a) { assert(a == 5_000) };
      case (null) { assert(false) };
    };
    mgr.unlock(n2);
  });

  test("toStable and loadStable roundtrip", func() {
    let mgr = Nonce.NonceManager(testPrincipal);
    let expiry = Time.now() + 300_000_000_000;

    let n1 = mgr.generate(expiry, testAmount);
    let n2 = mgr.generate(expiry, 2_000);
    let snapshot = mgr.toStable();

    let mgr2 = Nonce.NonceManager(testPrincipal);
    mgr2.loadStable(snapshot);

    assert(mgr2.exists(n1));
    assert(mgr2.exists(n2));

    // Verify amounts survive roundtrip
    switch (mgr2.lock(n1)) {
      case (?a) { assert(a == testAmount) };
      case (null) { assert(false) };
    };
    switch (mgr2.lock(n2)) {
      case (?a) { assert(a == 2_000) };
      case (null) { assert(false) };
    };
  });

  test("nonce is 32 bytes (SHA-256)", func() {
    let mgr = Nonce.NonceManager(testPrincipal);
    let nonce = mgr.generate(Time.now() + 300_000_000_000, testAmount);
    assert(nonce.size() == 32);
  });
});
